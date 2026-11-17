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
    AccountProvider.create!(account: account, provider: @santander_account)
  end

  test "counts imported and skipped rows and stays successful" do
    @santander_account.update!(raw_transactions_payload: {
      "m1" => row("m1", "purchase"),
      "m2" => row("m2", "refund")
    })

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_equal({ success: true, total: 2, imported: 1, skipped: 1, failed: 0, errors: [] }, result)
  end

  test "an over-long date or a non-finite amount is skipped, not failed" do
    @santander_account.update!(raw_transactions_payload: {
      "m1" => row("m1", "purchase"),
      "long" => row("long", "purchase", date: "2026-11-03" + " " * 200),
      "inf" => row("inf", "purchase", amount: "Infinity"),
      "nan" => row("nan", "purchase", amount: "NaN")
    })

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_equal({ success: true, total: 4, imported: 1, skipped: 3, failed: 0, errors: [] }, result)
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

  test "a stored payload that is not a Hash imports nothing and does not fail" do
    [ [ "x", 1 ], "junk" ].each do |junk|
      @santander_account.update_column(:raw_transactions_payload, junk)

      result = SantanderMxAccount::Transactions::Processor.new(@santander_account.reload).process

      assert_equal({ success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [] }, result)
    end
  end

  test "an exception while saving counts as failed" do
    @santander_account.update!(raw_transactions_payload: { "m1" => row("m1", "purchase") })
    Account::ProviderImportAdapter.any_instance.stubs(:import_transaction).raises(StandardError, "boom")

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process

    assert_not result[:success]
    assert_equal 1, result[:failed]
    assert_equal "m1", result[:errors].first[:transaction_id]
  end

  test "a purchase and a transfer_in move the linked card's ledger-driven balance" do
    account = @santander_account.current_account
    account.entries.create!(
      date: 10.days.ago.to_date, name: "Opening balance", amount: 1000, currency: "MXN",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @santander_account.update!(raw_transactions_payload: {
      "p1" => row("p1", "purchase", amount: 250.0, date: 3.days.ago.to_date.iso8601),
      "t1" => row("t1", "transfer_in", amount: 100.0, date: 2.days.ago.to_date.iso8601)
    })

    Account::MarketDataImporter.any_instance.stubs(:import_all)

    result = SantanderMxAccount::Transactions::Processor.new(@santander_account).process
    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))

    assert_equal 2, result[:imported]
    # A card balance is what is owed: the purchase adds to it and the incoming payment takes it down.
    assert_equal 1150, account.reload.balance
  end

  private
    def row(id, type, amount: 100.0, date: "2026-11-03T14:32:05")
      {
        "id" => id, "account" => "SANTANDER GOLD", "account_last4" => "1234",
        "date" => date, "amount" => amount, "currency" => "MXN",
        "type" => type, "description" => "EXAMPLE STORE", "details" => {}
      }
    end
end
