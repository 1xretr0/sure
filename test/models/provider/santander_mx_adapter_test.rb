require "test_helper"

class Provider::SantanderMxAdapterTest < ActiveSupport::TestCase
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
end
