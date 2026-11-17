require "test_helper"

# Pages that render an account call the linked provider adapter's institution lookups,
# so every Santander-linked account type must render each of them.
class SantanderMxLinkedAccountPagesTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @santander_account = santander_mx_accounts(:gold)
  end

  test "a linked credit card renders every page that shows it" do
    account = Account.create!(
      family: families(:dylan_family), name: "Santander Gold card", accountable: CreditCard.new,
      balance: 0, currency: "MXN"
    )

    assert_linked_account_pages_render(account, edit_credit_card_path(account))
  end

  test "a linked depository account renders every page that shows it" do
    account = Account.create!(
      family: families(:dylan_family), name: "Santander Gold debit", accountable: Depository.new,
      balance: 0, currency: "MXN"
    )

    assert_linked_account_pages_render(account, edit_depository_path(account))
  end

  test "the provider selection page offers Santander for an unlinked account" do
    item = santander_mx_items(:one)
    get select_provider_account_path(accounts(:depository))

    assert_response :success
    assert_select "a[href=?]", select_existing_account_santander_mx_items_path(santander_mx_item_id: item.id, account_id: accounts(:depository).id)
  end

  test "syncing and unlinking a linked account use the adapter without error" do
    account = accounts(:depository)
    @santander_account.ensure_account_provider!(account)

    assert_enqueued_with(job: SyncJob) { post sync_account_path(account) }
    assert_redirected_to account_path(account)

    delete unlink_account_path(account)
    assert_response :redirect
    assert_not account.reload.linked?
  end

  private
    def assert_linked_account_pages_render(account, edit_path)
      @santander_account.ensure_account_provider!(account)
      @santander_account.update!(raw_transactions_payload: {
        "m1" => row("m1", "purchase", amount: 250.0),
        "m2" => row("m2", "transfer_in", amount: 100.0)
      })
      SantanderMxAccount::Transactions::Processor.new(@santander_account).process
      entry = account.entries.find_by!(source: "santander_mx", external_id: "m1")
      assert_equal 2, account.entries.count

      [
        accounts_path,
        account_path(account),
        account_path(account, tab: "activity"),
        transactions_path,
        transaction_path(entry),
        edit_path,
        new_valuation_path(account_id: account.id),
        confirm_unlink_account_path(account)
      ].each do |path|
        get path
        assert_response :success, "GET #{path} responded #{response.status}"
      end
    end

    def row(id, type, amount:)
      {
        "id" => id, "account" => "SANTANDER GOLD", "account_last4" => "1234",
        "date" => "2026-11-03T14:32:05", "amount" => amount, "currency" => "MXN",
        "type" => type, "description" => "EXAMPLE STORE", "details" => {}
      }
    end
end
