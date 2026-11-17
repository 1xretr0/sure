# frozen_string_literal: true

# A connection to a self-hosted Santander MX statement parser (`base_url`), read with a
# bearer `api_token`. One item can reach several of the user's Santander accounts.
class SantanderMxItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  encrypts :api_token if encryption_ready?

  belongs_to :family
  has_many :santander_mx_accounts, dependent: :destroy
  has_many :accounts, through: :santander_mx_accounts

  validates :name, :base_url, presence: true
  validates :api_token, presence: true, on: :create
  validate :base_url_is_http_url

  scope :active, -> { where(scheduled_for_deletion: false) }
  # Family::Syncer discovers provider items reflectively and calls `syncable` on every
  # `*_items` association whose model includes Syncable.
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }

  def credentials_configured?
    base_url.present? && api_token.present?
  end

  # The bank is fixed, so the brand comes from the provider registry (also read by the adapter).
  def institution_name
    Provider::Metadata.for(:santander_mx)[:name]
  end
  alias_method :institution_display_name, :institution_name

  def institution_domain
    Provider::Metadata.for(:santander_mx)[:domain]
  end

  def institution_url
    "https://www.#{institution_domain}"
  end

  # Fetch the latest rows from the statement parser. Returns the importer's result hash.
  def import_latest_santander_mx_data
    provider = santander_mx_provider
    unless provider
      capture_sync_error("Cannot import: Santander MX provider is not configured")
      return { success: false, error: I18n.t("santander_mx_item.errors.not_configured") }
    end

    SantanderMxItem::Importer.new(self, provider: provider).import
  ensure
    # A rolled-back import leaves dirty cursor/status values on this instance.
    begin
      reload
    rescue ActiveRecord::RecordNotFound
      # The item was destroyed mid-sync; keep the import's own result or error.
    end
  end

  # Process each linked, visible Santander account, returning a per-account result array.
  def process_accounts
    santander_mx_accounts.joins(:account).merge(Account.visible).map do |santander_mx_account|
      result = SantanderMxAccount::Transactions::Processor.new(santander_mx_account).process
      if result.is_a?(Hash) && result.with_indifferent_access[:success] == false
        { santander_mx_account_id: santander_mx_account.id, success: false, error: I18n.t("santander_mx_item.errors.account_processing_failed") }
      else
        { santander_mx_account_id: santander_mx_account.id, success: true, result: result }
      end
    rescue => e
      capture_sync_error(
        "Failed to process account", e,
        account_provider: santander_mx_account.account_provider,
        santander_mx_account_id: santander_mx_account.id
      )
      { santander_mx_account_id: santander_mx_account.id, success: false, error: I18n.t("santander_mx_item.errors.account_processing_failed") }
    end
  end

  # Enqueue a balance sync for each visible linked account, returning per-account results.
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue => e
      capture_sync_error("Failed to schedule sync for account", e, account: account, account_id: account.id)
      { account_id: account.id, success: false, error: I18n.t("santander_mx_item.errors.account_sync_schedule_failed") }
    end
  end

  def linked_accounts_count
    account_counts[:linked]
  end

  def unlinked_accounts_count
    account_counts[:unlinked]
  end

  def total_accounts_count
    account_counts[:total]
  end

  # The counts are memoized for the settings partial, which asks for all three while
  # rendering one connection. A sync links an account midway through and then asks
  # again, so the memo has to go when the record is reloaded.
  def reload(*)
    @account_counts = nil
    super
  end

  private

    # Never put the API token or base URL in the metadata.
    def capture_sync_error(message, error = nil, account: nil, account_provider: nil, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: message,
        source: self.class.name,
        provider_key: "santander_mx",
        family: family,
        account: account,
        account_provider: account_provider,
        metadata: { santander_mx_item_id: id, error_class: error&.class&.name, error_message: error&.message }.compact.merge(metadata)
      )
    end

    def base_url_is_http_url
      return if base_url.blank?

      uri = URI.parse(base_url)
      errors.add(:base_url, :invalid) unless uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      errors.add(:base_url, :invalid)
    end

    def account_counts
      @account_counts ||= begin
        has_provider = santander_mx_accounts.left_joins(:account_provider)
                                            .pluck(Arel.sql("account_providers.id IS NOT NULL"))
        linked = has_provider.count(true)

        { linked: linked, unlinked: has_provider.size - linked, total: has_provider.size }
      end
    end
end
