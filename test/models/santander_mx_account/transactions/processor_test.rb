require "test_helper"

class SantanderMxAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @santander_account = santander_mx_accounts(:gold)
    account = Account.create!(
      family: @santander_account.santander_mx_item.family,
      name: "Santander Gold",
      accountable: CreditCard.new,
      balance: 0,
      currency: "MXN"
    )
    @santander_account.ensure_account_provider!(account)
  end

  test "counts imported and skipped rows and stays successful" do
    @santander_account.update!(raw_transactions_payload: {
      "m1" => row("m1", "purchase"),
      "m2" => row("m2", "refund")
    })

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_equal({ success: true, total: 2, imported: 1, skipped: 1, failed: 0, errors: [] }, result)
  end

  test "skips rows that are not hashes without failing" do
    @santander_account.update!(raw_transactions_payload: {
      "m1" => row("m1", "purchase"),
      "a" => "junk",
      "b" => 42,
      "c" => nil
    })

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_equal({ success: true, total: 4, imported: 1, skipped: 3, failed: 0, errors: [] }, result)
  end

  test "an empty payload is a successful no-op" do
    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_equal 0, result[:total]
    assert result[:success]
  end

  test "an exception while saving counts as failed" do
    @santander_account.update!(raw_transactions_payload: { "m1" => row("m1", "purchase") })
    Account::ProviderImportAdapter.any_instance.stubs(:import_transaction).raises(StandardError, "boom")

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_not result[:success]
    assert_equal 1, result[:failed]
    assert_equal "m1", result[:errors].first[:transaction_id]
  end

  private
    def row(id, type)
      {
        "id" => id, "account" => "SANTANDER GOLD", "account_last4" => "1234",
        "date" => "2026-11-03T14:32:05", "amount" => 100.0, "currency" => "MXN",
        "type" => type, "description" => "EXAMPLE STORE", "details" => {}
      }
    end
end
