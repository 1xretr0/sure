require "test_helper"

class SantanderMxEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @santander_account = santander_mx_accounts(:gold)
    @account = Account.create!(
      family: @santander_account.santander_mx_item.family,
      name: "Santander Gold",
      accountable: CreditCard.new,
      balance: 0,
      currency: "MXN"
    )
    @santander_account.ensure_account_provider!(@account)
  end

  test "books a purchase as an outflow" do
    entry = process(row)

    assert_equal 1250, entry.amount
    assert_equal "santander_mx", entry.source
    assert_equal "m1", entry.external_id
    assert_equal "EXAMPLE STORE", entry.name
    assert_equal Date.new(2026, 11, 3), entry.date
  end

  test "books transfer_out positive and transfer_in negative" do
    assert_equal 1250, process(row("id" => "m2", "type" => "transfer_out")).amount
    assert_equal(-1250, process(row("id" => "m3", "type" => "transfer_in")).amount)
  end

  test "uses the absolute amount when the service still sends a signed one" do
    assert_equal 1250, process(row("amount" => -1250.0)).amount
  end

  test "keeps a late-evening transaction on its own date" do
    assert_equal Date.new(2026, 11, 3), process(row("date" => "2026-11-03T23:50:00")).date
  end

  test "skips an unknown type" do
    assert_skipped row("type" => "refund")
  end

  test "skips a blank id" do
    assert_skipped row("id" => "")
  end

  test "skips an unparseable amount" do
    assert_skipped row("amount" => "abc")
  end

  test "skips an unparseable date" do
    assert_skipped row("date" => "not a date")
  end

  test "skips a row that is not a hash" do
    [ "junk", 42, nil, [ 1 ] ].each { |junk| assert_skipped junk }
  end

  test "skips a row for an account that is not linked" do
    @santander_account.account_provider.destroy!

    assert_no_difference -> { Entry.count } do
      assert_nil SantanderMxEntry::Processor.new(row, santander_mx_account: @santander_account.reload).process
    end
  end

  test "falls back to a per-type name when description is blank" do
    assert_equal "Santander purchase", process(row("description" => "")).name
  end

  test "uses the linked account's currency when the row has none" do
    assert_equal "MXN", process(row("id" => "m2", "currency" => nil)).currency
    assert_equal "MXN", process(row("id" => "m3", "currency" => "")).currency
  end

  test "keeps a row's own currency over the account's" do
    assert_equal "USD", process(row("currency" => "USD")).currency
  end

  test "truncates a very long description to 255 characters" do
    assert_equal 255, process(row("description" => "X" * 400)).name.length
  end

  test "books a zero amount as a zero entry for either direction" do
    assert_equal 0, process(row("id" => "z1", "amount" => "0.00")).amount
    assert_equal 0, process(row("id" => "z2", "amount" => 0, "type" => "transfer_in")).amount
  end

  test "stores type, last4 and details under extra" do
    entry = process(row("details" => { "merchant" => "X" }))

    assert_equal(
      { "type" => "purchase", "last4" => "1234", "details" => { "merchant" => "X" } },
      entry.entryable.extra["santander_mx"]
    )
  end

  test "re-importing the same row does not duplicate" do
    process(row)

    assert_no_difference -> { @account.entries.count } do
      process(row)
    end
  end

  test "claims a matching hand-entered entry" do
    manual = @account.entries.create!(
      name: "Manual", date: Date.new(2026, 11, 3), amount: 1250, currency: "MXN",
      entryable: Transaction.new
    )

    assert_no_difference -> { @account.entries.count } do
      process(row)
    end
    assert_equal "m1", manual.reload.external_id
  end

  private
    def row(overrides = {})
      {
        "id" => "m1", "account" => "SANTANDER GOLD", "account_last4" => "1234",
        "date" => "2026-11-03T14:32:05", "amount" => 1250.0, "currency" => "MXN",
        "type" => "purchase", "description" => "EXAMPLE STORE", "details" => {}
      }.merge(overrides)
    end

    def process(data)
      SantanderMxEntry::Processor.new(data, santander_mx_account: @santander_account).process
    end

    def assert_skipped(data)
      assert_no_difference -> { Entry.count } do
        assert_difference -> { DebugLogEntry.where(provider_key: "santander_mx").count }, 1 do
          assert_nil process(data)
        end
      end
    end
end
