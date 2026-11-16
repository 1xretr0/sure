require "test_helper"

class SantanderMxAccountTest < ActiveSupport::TestCase
  test "names are unique per item" do
    item = santander_mx_items(:one)
    duplicate = item.santander_mx_accounts.new(name: santander_mx_accounts(:gold).name)

    assert_not duplicate.valid?
    assert duplicate.errors[:name].any?
  end

  test "unlinked excludes accounts with an account provider" do
    gold = santander_mx_accounts(:gold)
    assert_includes SantanderMxAccount.unlinked, gold

    gold.ensure_account_provider!(accounts(:depository))
    assert_not_includes SantanderMxAccount.unlinked, gold
    assert_equal accounts(:depository), gold.current_account
  end
end
