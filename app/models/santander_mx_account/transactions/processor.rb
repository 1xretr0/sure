# frozen_string_literal: true

class SantanderMxAccount::Transactions::Processor
  attr_reader :santander_mx_account

  def initialize(santander_mx_account)
    @santander_mx_account = santander_mx_account
  end

  # Replays the whole stored payload on every sync; entries are matched on the row id, so
  # re-processing a row updates the entry it already produced. A row the entry processor
  # declines counts as skipped, never failed: it never becomes usable, so failing on it
  # would fail every later sync.
  def process
    rows = santander_mx_account.raw_transactions_payload.to_h.values

    imported = skipped = failed = 0
    errors = []

    rows.each_with_index do |row, index|
      if SantanderMxEntry::Processor.new(row, santander_mx_account: santander_mx_account).process
        imported += 1
      else
        skipped += 1
      end
    rescue => e
      failed += 1
      errors << { index: index, transaction_id: (row.is_a?(Hash) && row["id"]) || "unknown", error: "#{e.class}: #{e.message}" }
      Rails.logger.error "SantanderMxAccount::Transactions::Processor - Error processing row #{row.is_a?(Hash) ? row["id"] : "unknown"}: #{e.class} - #{e.message}"
    end

    { success: failed.zero?, total: rows.size, imported: imported, skipped: skipped, failed: failed, errors: errors }
  end
end
