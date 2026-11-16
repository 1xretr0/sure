module Family::SantanderMxConnectable
  extend ActiveSupport::Concern

  included do
    has_many :santander_mx_items, dependent: :destroy
  end

  # Create a Santander MX connection to a self-hosted statement parser and start its
  # first sync.
  def create_santander_mx_item!(base_url:, api_token:, item_name: nil, sync_start_date: nil)
    santander_mx_item = santander_mx_items.create!(
      name: item_name.presence || I18n.t("family.santander_mx.create_santander_mx_item.default_name"),
      base_url: base_url,
      api_token: api_token,
      sync_start_date: sync_start_date
    )

    santander_mx_item.sync_later
    santander_mx_item
  end
end
