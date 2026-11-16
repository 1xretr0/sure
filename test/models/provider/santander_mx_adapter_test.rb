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

  test "a Santander-linked account has ledger-driven balances" do
    account = accounts(:credit_card)
    santander_mx_accounts(:gold).ensure_account_provider!(account)

    refute account.reload.balance_from_provider?
  end
end
