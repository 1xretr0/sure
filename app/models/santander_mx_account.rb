# frozen_string_literal: true

# One Santander account (or card) as named by the statement parser's feed.
class SantanderMxAccount < ApplicationRecord
  include Encryptable

  encrypts :raw_transactions_payload if encryption_ready?

  belongs_to :santander_mx_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, presence: true, uniqueness: { scope: :santander_mx_item_id }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }

  def current_account
    account
  end

  # Idempotently create or update the AccountProvider link.
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear the cached nil.
    reload_account_provider
    account_provider
  end
end
