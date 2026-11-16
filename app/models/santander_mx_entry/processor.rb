# frozen_string_literal: true

# Maps one row of the statement parser's feed onto a Sure entry.
class SantanderMxEntry::Processor
  # The service reports every amount as a positive magnitude; the type alone decides
  # the direction. Sure stores an outflow positive.
  SIGNS = { "purchase" => 1, "transfer_out" => 1, "transfer_in" => -1 }.freeze

  def initialize(row, santander_mx_account:)
    @row = row.to_h.with_indifferent_access
    @santander_mx_account = santander_mx_account
  end

  # Returns nil when the row cannot be imported: no linked account, or an unusable
  # id, date, amount or type. Saving errors propagate to the caller.
  def process
    return skip("No linked account") if account.blank?
    return skip("Row has no id") if external_id.blank?
    return skip("Unknown transaction type") unless SIGNS.key?(type)
    return skip("Unparseable date") if date.nil?
    return skip("Unparseable amount") if amount.nil?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: row[:currency].presence || account.currency,
      date: date,
      name: name,
      source: "santander_mx",
      extra: { "santander_mx" => { "type" => type, "last4" => row[:account_last4], "details" => row[:details] } },
      replace_extra_namespaces: [ "santander_mx" ]
    )
  end

  private
    attr_reader :row, :santander_mx_account

    def account
      @account ||= santander_mx_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def external_id
      row[:id].to_s.presence
    end

    def type
      row[:type].to_s
    end

    def amount
      return @amount if defined?(@amount)

      @amount = SIGNS.fetch(type) * BigDecimal(row[:amount].to_s).abs
    rescue ArgumentError, KeyError
      @amount = nil
    end

    # Parsed from the string so a late-evening time never shifts the day.
    def date
      return @date if defined?(@date)

      @date = Date.parse(row[:date].to_s)
    rescue Date::Error
      @date = nil
    end

    def name
      (row[:description].presence || I18n.t("santander_mx.entry.fallback_name.#{type}")).to_s.truncate(255)
    end

    def skip(reason)
      DebugLogEntry.capture(
        category: "provider_sync_warning",
        level: "warn",
        message: "Skipped Santander MX row: #{reason}",
        source: self.class.name,
        provider_key: "santander_mx",
        family: santander_mx_account.santander_mx_item.family,
        account_provider: santander_mx_account.account_provider,
        metadata: { santander_mx_account_id: santander_mx_account.id, row_id: row[:id], type: row[:type] }
      )
      nil
    end
end
