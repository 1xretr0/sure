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
