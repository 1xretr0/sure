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
    response = provider.get_transactions(since: since)
    rows = usable_rows(response[:transactions])
    unparsed = Array(response[:unparsed])

    SantanderMxItem.transaction do
      accounts_seen = store_rows(rows)
      log_unparsed(unparsed) if unparsed.any?
      santander_mx_item.update!(transactions_synced_through: Date.current, status: :good)

      { success: true, accounts_seen: accounts_seen, transactions_seen: rows.size, unparsed_count: unparsed.size }
    end
  rescue Provider::SantanderMx::AuthenticationError, Provider::SantanderMx::ReauthorizationRequiredError => e
    santander_mx_item.update!(status: :requires_update)
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
        if row.is_a?(Hash) && row["id"].present? && row["account"].to_s.strip.present?
          by_id[row["id"].to_s] = row
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

    # Returns the number of products the response touched.
    def store_rows(rows)
      incoming_owner = rows.to_h { |row| [ row["id"].to_s, row["account"].to_s ] }
      by_product = rows.group_by { |row| row["account"].to_s }

      by_product.each do |name, product_rows|
        account = find_or_create_account(name)
        last4 = product_rows.reverse.filter_map { |row| row["account_last4"].presence }.first
        currency = product_rows.reverse.filter_map { |row| row["currency"].presence }.first
        account.assign_attributes({ last4: last4, currency: currency }.compact)
        account.save!
      end

      # A row whose product changed leaves its old product, so no entry is processed twice.
      santander_mx_item.santander_mx_accounts.reload.each do |account|
        payload = account.raw_transactions_payload.to_h
        merged = payload.reject { |id, _| incoming_owner[id] && incoming_owner[id] != account.name }
        by_product.fetch(account.name, []).each { |row| merged[row["id"].to_s] = row }
        account.update!(raw_transactions_payload: merged) if merged != payload
      end

      by_product.size
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
