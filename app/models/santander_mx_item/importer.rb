# frozen_string_literal: true

# Makes the one service request of a sync and stores the rows it returns, raw, on the
# product (`SantanderMxAccount`) each row names. Turning rows into entries is
# SantanderMxAccount::Transactions::Processor's job.
#
# The service filters by email date, so a sync re-reads a few days before the last cursor.
# Rows carry stable Gmail ids and are merged by id, which makes the overlap harmless.
class SantanderMxItem::Importer
  LOOKBACK_DAYS = 3
  INITIAL_HISTORY_DAYS = 90

  attr_reader :santander_mx_item, :provider

  def initialize(santander_mx_item, provider:)
    @santander_mx_item = santander_mx_item
    @provider = provider
  end

  def since
    if santander_mx_item.transactions_synced_through
      santander_mx_item.transactions_synced_through - LOOKBACK_DAYS
    else
      santander_mx_item.sync_start_date || Date.current - INITIAL_HISTORY_DAYS
    end
  end

  # Returns `{ success: true, accounts_seen:, transactions_seen:, unparsed_count: }` or
  # `{ success: false, error: }`. A failure never moves the cursor.
  def import
    # Taken before the fetch so a sync that crosses midnight re-reads, not skips, that day.
    synced_through = Date.current
    response = provider.get_transactions(since: since)
    rows = usable_rows(response[:transactions])
    unparsed = Array(response[:unparsed])

    SantanderMxItem.transaction do
      # Serializes overlapping syncs of this item; the lock is held until the transaction ends.
      # A fresh query, because `lock!` on this instance raises when it has unsaved changes.
      SantanderMxItem.lock.find(santander_mx_item.id)

      accounts_seen = store_rows(rows)
      log_unparsed(unparsed) if unparsed.any?
      # No validations or dirty attributes: the cursor must move whatever else the item holds.
      santander_mx_item.update_columns(transactions_synced_through: synced_through, status: "good", updated_at: Time.current)

      { success: true, accounts_seen: accounts_seen, transactions_seen: rows.size, unparsed_count: unparsed.size }
    end
  rescue Provider::SantanderMx::AuthenticationError, Provider::SantanderMx::ReauthorizationRequiredError => e
    santander_mx_item.update_columns(status: "requires_update", updated_at: Time.current)
    capture_error("Santander MX service rejected the connection", e)
    failed(e.is_a?(Provider::SantanderMx::ReauthorizationRequiredError) ? e.message : I18n.t("santander_mx_item.errors.unauthorized"))
  rescue Provider::SantanderMx::Error => e
    capture_error("Failed to fetch Santander MX transactions", e)
    failed(e.message)
  rescue StandardError => e
    # Network, TLS and database errors can echo request details, so only the class is kept.
    capture_error("Unexpected error importing Santander MX transactions", e, include_message: false)
    failed(I18n.t("santander_mx_item.errors.sync_failed"))
  end

  private

    # Rows by id (the last copy wins), dropping what cannot be stored. Skips are logged once.
    def usable_rows(transactions)
      skipped = 0
      by_id = {}

      Array(transactions).each do |row|
        if row.is_a?(Hash) && usable_id?(row["id"]) && row["account"].is_a?(String) && row["account"].strip.present?
          by_id[row["id"].to_s] = row.merge("account" => row["account"].strip)
        else
          skipped += 1
        end
      end

      if skipped.positive?
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "warn",
          message: "Skipped Santander MX rows without an id or account",
          source: self.class.name,
          provider_key: "santander_mx",
          family: santander_mx_item.family,
          metadata: { santander_mx_item_id: santander_mx_item.id, skipped_count: skipped }
        )
      end

      by_id.values
    end

    def usable_id?(id)
      (id.is_a?(String) && id.present?) || id.is_a?(Integer)
    end

    # Returns the number of products the response touched.
    def store_rows(rows)
      incoming_owner = rows.to_h { |row| [ row["id"].to_s, row["account"] ] }
      by_product = rows.group_by { |row| row["account"] }

      by_product.each do |name, product_rows|
        account = find_or_create_account(name)
        last4 = latest_value(product_rows, "account_last4")
        currency = latest_value(product_rows, "currency")
        account.assign_attributes({ last4: last4, currency: currency }.compact)
        account.save!
      end

      # A row whose product changed leaves its old product, so no entry is processed twice.
      santander_mx_item.santander_mx_accounts.reload.each do |account|
        payload = account.raw_transactions_payload
        payload = {} unless payload.is_a?(Hash)
        merged = payload.reject { |id, _| incoming_owner[id] && incoming_owner[id] != account.name }
        by_product.fetch(account.name, []).each { |row| merged[row["id"].to_s] = row }
        account.update!(raw_transactions_payload: merged) if merged != payload
      end

      by_product.size
    end

    # The value of the newest row (by date, later in the response on a tie) that has one.
    def latest_value(rows, key)
      rows.each_with_index
          .select { |row, _| row[key].present? }
          .max_by { |row, index| [ row_date(row), index ] }
          &.first&.fetch(key)
    end

    def row_date(row)
      Date.parse(row["date"].to_s)
    rescue ArgumentError
      Date.new(0)
    end

    # The unique index on (item, name) is the arbiter between concurrent syncs.
    def find_or_create_account(name)
      retried = false
      begin
        SantanderMxAccount.transaction(requires_new: true) do
          santander_mx_item.santander_mx_accounts.find_or_create_by!(name: name)
        end
      rescue ActiveRecord::RecordNotUnique
        raise if retried

        retried = true
        retry
      end
    end

    def log_unparsed(unparsed)
      messages = unparsed.map do |message|
        message.is_a?(Hash) ? message.slice("id", "subject", "received_at") : {}
      end

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Santander MX could not parse #{unparsed.size} email(s)",
        source: self.class.name,
        provider_key: "santander_mx",
        family: santander_mx_item.family,
        metadata: { santander_mx_item_id: santander_mx_item.id, unparsed: messages }
      )
    end

    def capture_error(message, error, include_message: true)
      metadata = { santander_mx_item_id: santander_mx_item.id, error_class: error.class.name }
      metadata[:error_message] = error.message if include_message
      metadata[:error_type] = error.failure_code if error.respond_to?(:failure_code)

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: message,
        source: self.class.name,
        provider_key: "santander_mx",
        family: santander_mx_item.family,
        metadata: metadata
      )
    end

    def failed(error)
      { success: false, error: error }
    end
end
