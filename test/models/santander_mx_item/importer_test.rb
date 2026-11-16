require "test_helper"

class SantanderMxItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = SantanderMxItem.create!(
      family: families(:empty), name: "Santander", base_url: "http://parser.test", api_token: "secret-token"
    )
    @provider = mock("provider")
  end

  test "first sync reads from sync_start_date" do
    @item.update!(sync_start_date: Date.new(2026, 10, 1))
    @provider.expects(:get_transactions).with(since: Date.new(2026, 10, 1)).returns(response)

    assert import[:success]
  end

  test "first sync defaults to 90 days back" do
    travel_to Date.new(2026, 11, 15) do
      @provider.expects(:get_transactions).with(since: Date.new(2026, 11, 15) - 90).returns(response)

      assert import[:success]
    end
  end

  test "later syncs re-read three days before the cursor" do
    @item.update!(transactions_synced_through: Date.new(2026, 11, 10), sync_start_date: Date.new(2026, 1, 1))
    @provider.expects(:get_transactions).with(since: Date.new(2026, 11, 7)).returns(response)

    assert import[:success]
  end

  test "advances the cursor and marks the item good on success" do
    @item.update!(status: :requires_update)
    @provider.stubs(:get_transactions).returns(response)

    travel_to Date.new(2026, 11, 15) do
      assert import[:success]
    end

    @item.reload
    assert_equal Date.new(2026, 11, 15), @item.transactions_synced_through
    assert @item.good?
  end

  test "groups rows into one account per product and merges rows by id" do
    rows = [ row("a", "GOLD", "1234"), row("b", "GOLD", "1234"), row("c", "SANTANDER", nil, currency: "USD") ]
    @provider.stubs(:get_transactions).returns(response(rows))

    result = import

    assert_equal({ success: true, accounts_seen: 2, transactions_seen: 3, unparsed_count: 0 }, result)
    gold = @item.santander_mx_accounts.find_by!(name: "GOLD")
    assert_equal %w[a b], gold.raw_transactions_payload.keys.sort
    assert_equal "1234", gold.last4
    assert_equal "MXN", gold.currency
    assert_equal "USD", @item.santander_mx_accounts.find_by!(name: "SANTANDER").currency

    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil, amount: "99.00") ]))
    import

    gold.reload
    assert_equal 2, gold.raw_transactions_payload.size
    assert_equal "99.00", gold.raw_transactions_payload["a"]["amount"]
    assert_equal "1234", gold.last4
  end

  test "skips a row with a blank account without creating an account" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "", nil), row("b", nil, nil), row("c", "GOLD", nil) ]))

    assert_difference -> { @item.santander_mx_accounts.count }, 1 do
      result = import
      assert_equal 1, result[:transactions_seen]
    end
    assert_equal 1, DebugLogEntry.where(provider_key: "santander_mx", category: "provider_sync").count
  end

  test "skips rows that are not hashes or have a blank id" do
    @provider.stubs(:get_transactions).returns(response([ "junk", nil, row("", "GOLD", nil), row("c", "GOLD", nil) ]))

    result = import

    assert result[:success]
    assert_equal 1, result[:transactions_seen]
    assert_equal %w[c], @item.santander_mx_accounts.find_by!(name: "GOLD").raw_transactions_payload.keys
  end

  test "moves a row whose id now belongs to another product" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil), row("b", "GOLD", nil) ]))
    import

    @provider.stubs(:get_transactions).returns(response([ row("a", "SANTANDER", nil) ]))
    import

    assert_equal %w[b], @item.santander_mx_accounts.find_by!(name: "GOLD").raw_transactions_payload.keys
    assert_equal %w[a], @item.santander_mx_accounts.find_by!(name: "SANTANDER").raw_transactions_payload.keys
  end

  test "an empty successful response advances the cursor and keeps payloads" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))
    import
    @provider.stubs(:get_transactions).returns(response)

    travel_to Date.new(2026, 12, 1) do
      result = import
      assert_equal({ success: true, accounts_seen: 0, transactions_seen: 0, unparsed_count: 0 }, result)
    end

    assert_equal Date.new(2026, 12, 1), @item.reload.transactions_synced_through
    assert_equal %w[a], @item.santander_mx_accounts.find_by!(name: "GOLD").raw_transactions_payload.keys
  end

  test "retries the lookup when another sync creates the product first" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))
    existing = @item.santander_mx_accounts.create!(name: "GOLD")
    @item.santander_mx_accounts.stubs(:find_or_create_by!).raises(ActiveRecord::RecordNotUnique).then.returns(existing)

    assert import[:success]
  end

  test "logs unparsed messages" do
    unparsed = [ { "id" => "m1", "subject" => "Hola", "received_at" => "2026-11-01T10:00:00Z", "body" => "secret" } ]
    @provider.stubs(:get_transactions).returns(response([], unparsed))

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "santander_mx").count }, 1 do
      result = import
    end

    assert_equal 1, result[:unparsed_count]
    entry = DebugLogEntry.where(provider_key: "santander_mx").last
    assert_equal "warn", entry.level
    refute_includes entry.metadata.to_s, "secret"
  end

  test "401 marks the item requires_update and keeps the cursor" do
    @item.update!(transactions_synced_through: Date.new(2026, 11, 1))
    @provider.stubs(:get_transactions).raises(Provider::SantanderMx::AuthenticationError.new("rejected", failure_code: :unauthorized))

    result = import

    assert_not result[:success]
    assert_equal I18n.t("santander_mx_item.errors.unauthorized"), result[:error]
    assert @item.reload.requires_update?
    assert_equal Date.new(2026, 11, 1), @item.transactions_synced_through
  end

  test "503 marks the item requires_update with the service message" do
    @provider.stubs(:get_transactions).raises(
      Provider::SantanderMx::ReauthorizationRequiredError.new("Re-authorize Gmail on the host", failure_code: :reauthorization_required)
    )

    result = import

    assert_equal "Re-authorize Gmail on the host", result[:error]
    assert @item.reload.requires_update?
    assert_nil @item.transactions_synced_through
  end

  test "a server error keeps the status and the cursor" do
    @item.update!(transactions_synced_through: Date.new(2026, 11, 1))
    @provider.stubs(:get_transactions).raises(Provider::SantanderMx::Error.new("boom", failure_code: :server_error))

    result = import

    assert_not result[:success]
    assert_equal "boom", result[:error]
    assert @item.reload.good?
    assert_equal Date.new(2026, 11, 1), @item.transactions_synced_through
  end

  test "an unexpected error is a failed import that leaves status and cursor alone and never logs the token" do
    @provider.stubs(:get_transactions).raises(OpenSSL::SSL::SSLError.new("bad cert for secret-token"))

    assert_difference -> { DebugLogEntry.where(provider_key: "santander_mx").count }, 1 do
      result = import
      assert_not result[:success]
      assert_not_includes result[:error], "secret-token"
    end

    assert @item.reload.good?
    assert_nil @item.transactions_synced_through
    assert_not_includes DebugLogEntry.where(provider_key: "santander_mx").last.metadata.to_s, "secret-token"
  end

  private

    def import
      SantanderMxItem::Importer.new(@item, provider: @provider).import
    end

    def response(transactions = [], unparsed = [])
      { "transactions" => transactions, "unparsed" => unparsed }.with_indifferent_access
    end

    def row(id, account, last4, currency: "MXN", amount: "10.00")
      { "id" => id, "account" => account, "account_last4" => last4, "currency" => currency, "amount" => amount }
    end
end
