# frozen_string_literal: true

class SantanderMxItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  # Error carrying the structured per-stage sync errors for health reporting.
  class SyncError < StandardError
    attr_reader :sync_errors

    def initialize(message, sync_errors:)
      super(message)
      @sync_errors = sync_errors
    end
  end

  attr_reader :santander_mx_item

  def initialize(santander_mx_item)
    @santander_mx_item = santander_mx_item
  end

  # Run the full sync: import, transaction processing, balance sync scheduling, and
  # stats/health collection. Raises on failures.
  def perform_sync(sync)
    update_status(sync, "importing")
    import_result = santander_mx_item.import_latest_santander_mx_data
    raise_if_failed_result!(import_result, stage: "Santander MX import")
    merge_sync_stats(sync, "unparsed_count" => import_result[:unparsed_count])

    update_status(sync, "checking_setup")
    collect_setup_stats(sync, provider_accounts: santander_mx_item.santander_mx_accounts)

    linked_accounts = santander_mx_item.santander_mx_accounts.joins(:account_provider)
    unlinked_count = santander_mx_item.santander_mx_accounts.unlinked.count
    update_status(sync, "needs_setup", count: unlinked_count) if unlinked_count.positive?

    if linked_accounts.any?
      update_status(sync, "processing")
      mark_import_started(sync)
      process_results = santander_mx_item.process_accounts
      raise_if_failed_results!(process_results, stage: "Santander MX account processing")

      update_status(sync, "calculating")
      schedule_results = santander_mx_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
      raise_if_failed_results!(schedule_results, stage: "Santander MX account sync scheduling")

      account_ids = linked_accounts.includes(:account_provider).filter_map { |account| account.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "santander_mx")
    else
      Rails.logger.info "SantanderMxItem::Syncer - No linked accounts to process"
    end

    collect_health_stats(sync, errors: nil)
  rescue SyncError => e
    collect_health_stats(sync, errors: e.sync_errors)
    raise
  rescue => e
    safe_message = I18n.t("santander_mx_item.errors.sync_failed")
    # Class only: a network or database error can echo the request URL.
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Unexpected sync error",
      source: self.class.name,
      provider_key: "santander_mx",
      family: santander_mx_item.family,
      metadata: { santander_mx_item_id: santander_mx_item.id, error_class: e.class.name }
    )
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError.new(safe_message), cause: nil
  end

  # Post-sync hook (no work required for Santander MX).
  def perform_post_sync
    # no-op
  end

  private

    def update_status(sync, key, **options)
      sync.update!(status_text: I18n.t("santander_mx_item.sync.status.#{key}", **options)) if sync.respond_to?(:status_text)
    end

    # Raise a SyncError if a single result hash indicates failure.
    def raise_if_failed_result!(result, stage:)
      return unless failed_result?(result)

      errors = errors_from_result(result, stage: stage)
      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    # Raise a SyncError if any result in the collection indicates failure.
    def raise_if_failed_results!(results, stage:)
      errors = Array(results).filter_map do |result|
        next unless failed_result?(result)

        errors_from_result(result, stage: stage).first
      end

      return if errors.empty?

      raise SyncError.new(error_message(stage, errors), sync_errors: errors)
    end

    # True when +result+ is a hash explicitly flagged success: false.
    def failed_result?(result)
      result.is_a?(Hash) && result.with_indifferent_access[:success] == false
    end

    # Normalize a failed result into an array of { message:, category: } errors.
    def errors_from_result(result, stage:)
      data = result.with_indifferent_access
      messages = []
      messages << data[:error] if data[:error].present?
      messages.concat(Array(data[:errors]).map { |error| error_message_value(error) }.compact)
      messages << "#{stage} failed" if messages.empty?

      messages.map { |message| { message: "#{stage}: #{message}", category: "sync_error" } }
    end

    # Join the error messages into a single stage summary string.
    def error_message(stage, errors)
      messages = errors.map { |error| error[:message] || error["message"] }.compact
      messages.presence&.join(", ") || "#{stage} failed"
    end

    # Extract a human-readable message from a heterogeneous error value.
    def error_message_value(error)
      return error[:message].presence || error["message"].presence || error[:error].presence || error["error"].presence if error.is_a?(Hash)

      error.to_s.presence
    end
end
