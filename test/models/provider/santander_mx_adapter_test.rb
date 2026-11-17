require "test_helper"

class Provider::SantanderMxAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  # The shared contract every adapter must meet, including the calls the app makes on a linked
  # account (institution lookups, item, sync_path, raw_payload, metadata).
  def adapter
    Provider::Factory.create_adapter(santander_mx_accounts(:gold))
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "is registered for SantanderMxAccount" do
    assert_instance_of Provider::SantanderMxAdapter, Provider::Factory.create_adapter(santander_mx_accounts(:gold))
  end

  test "supports credit cards and depository accounts" do
    assert_equal %w[CreditCard Depository], Provider::SantanderMxAdapter.supported_account_types
  end

  test "does not report balances" do
    refute Provider::Factory.create_adapter(santander_mx_accounts(:gold)).reports_balance?
  end

  test "offers no new-account path" do
    configs = Provider::SantanderMxAdapter.connection_configs(family: families(:dylan_family))

    assert_equal [ "santander_mx_#{santander_mx_items(:one).id}" ], configs.map { |c| c[:key] }
    configs.each { |config| assert_nil config[:new_account_path] }
  end

  test "connection_configs skips items scheduled for deletion and items without credentials" do
    family = families(:empty)
    assert_equal [], Provider::SantanderMxAdapter.connection_configs(family: family)

    kept = family.santander_mx_items.create!(name: "Kept", base_url: "http://parser.test", api_token: "t")
    family.santander_mx_items.create!(name: "Deleting", base_url: "http://parser.test", api_token: "t", scheduled_for_deletion: true)
    # Credentials are validated on save, so a blank one has to be written past validation.
    family.santander_mx_items.create!(name: "No token", base_url: "http://parser.test", api_token: "t").update_columns(api_token: "")

    configs = Provider::SantanderMxAdapter.connection_configs(family: family)

    assert_equal [ "santander_mx_#{kept.id}" ], configs.map { |config| config[:key] }
    assert_equal [ "Kept" ], configs.map { |config| config[:name] }
  end

  test "a Santander-linked account has ledger-driven balances" do
    account = accounts(:credit_card)
    santander_mx_accounts(:gold).ensure_account_provider!(account)

    refute account.reload.balance_from_provider?
  end

  test "institution metadata comes from the provider registry" do
    adapter = Provider::Factory.create_adapter(santander_mx_accounts(:gold))

    assert_equal "santander.com.mx", adapter.institution_domain
    assert_equal "Santander México", adapter.institution_name
    assert_equal "https://www.santander.com.mx", adapter.institution_url
    assert_equal "#ec0000", adapter.institution_color
    assert_nil adapter.logo_url
    assert_equal(
      { domain: "santander.com.mx", name: "Santander México", url: "https://www.santander.com.mx", color: "#ec0000" },
      adapter.institution_metadata
    )
    assert_equal adapter.institution_metadata, adapter.metadata[:institution]
  end

  test "institution lookups return nil when the account has no item" do
    adapter = Provider::Factory.create_adapter(SantanderMxAccount.new)

    assert_nil adapter.institution_domain
    assert_nil adapter.institution_name
    assert_nil adapter.institution_url
    assert_nothing_raised { adapter.metadata }
  end
end
