# frozen_string_literal: true

module SantanderMxItem::Provided
  extend ActiveSupport::Concern

  def santander_mx_provider
    return nil unless credentials_configured?

    Provider::SantanderMx.new(base_url: base_url, api_token: api_token)
  end

  def syncer
    SantanderMxItem::Syncer.new(self)
  end
end
