# frozen_string_literal: true

class Provider::SantanderMxAdapter < Provider::Base
  include Provider::Syncable

  Provider::Factory.register("SantanderMxAccount", self)

  # The parser feed names accounts and cards; a card is a CreditCard, anything else Depository.
  def self.supported_account_types
    %w[CreditCard Depository]
  end

  # One config per credentialed connection. Accounts come from the parser feed, so there is
  # no new-account flow; the settings panel links feed accounts to existing ones.
  def self.connection_configs(family:)
    family.santander_mx_items.active.ordered.select(&:credentials_configured?).map do |item|
      {
        key: "santander_mx_#{item.id}",
        name: item.name.presence || I18n.t("providers.santander_mx.name"),
        description: I18n.t("providers.santander_mx.description"),
        can_connect: true,
        new_account_path: nil,
        existing_account_path: ->(account_id) {
          Rails.application.routes.url_helpers.select_existing_account_santander_mx_items_path(
            santander_mx_item_id: item.id, account_id: account_id
          )
        }
      }
    end
  end

  def self.connection_item_class
    SantanderMxItem
  end

  def provider_name
    "santander_mx"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_santander_mx_item_path(item)
  end

  def item
    provider_account.santander_mx_item
  end

  # Statements carry no balance, so the ledger drives it.
  def reports_balance?
    false
  end
end
