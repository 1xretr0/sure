# frozen_string_literal: true

module SantanderMxItem::Unlinking
  # Concern that encapsulates unlinking logic for a Santander MX item.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this Santander MX item and local accounts.
  # - Detaches any AccountProvider links for each SantanderMxAccount
  # Santander MX imports transactions only, so no Holding ever points at these links.
  # Returns a per-account result payload for observability
  def unlink_all!(dry_run: false)
    results = []

    santander_mx_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: "SantanderMxAccount", provider_id: provider_account.id).to_a
      link_ids = links.map(&:id)
      result = {
        provider_account_id: provider_account.id,
        name: provider_account.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          links.each(&:destroy!)
        end
      rescue StandardError => e
        Rails.logger.warn(
          "SantanderMxItem Unlinker: failed to fully unlink provider account ##{provider_account.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other accounts
        result[:error] = e.message
      end
    end

    results
  end
end
