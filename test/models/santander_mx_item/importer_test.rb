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

  test "logs unparsed messages with their id, subject and date but never their content" do
    unparsed = [
      { "id" => "m1", "subject" => "Hola", "received_at" => "2026-11-01T10:00:00Z", "body" => "PII-BODY " * 200 },
      { "id" => "m2", "subject" => "Adios", "received_at" => "2026-11-02T08:30:00Z", "snippet" => "PII-SNIPPET", "from" => "pii@example.com" }
    ]
    @provider.stubs(:get_transactions).returns(response([], unparsed))

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "santander_mx").count }, 1 do
      result = import
    end

    assert result[:success]
    assert_equal 2, result[:unparsed_count]
    entry = DebugLogEntry.where(provider_key: "santander_mx").sole
    assert_equal "provider_sync", entry.category
    assert_equal "warn", entry.level
    assert_equal @item.family, entry.family
    assert_equal(
      [ { "id" => "m1", "subject" => "Hola", "received_at" => "2026-11-01T10:00:00Z" },
        { "id" => "m2", "subject" => "Adios", "received_at" => "2026-11-02T08:30:00Z" } ],
      entry.metadata["unparsed"]
    )
    assert_not_includes entry.to_json, "PII"
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

  {
    "a rejected request" => Provider::SantanderMx::Error.new("since is required", failure_code: :bad_request),
    "a service error" => Provider::SantanderMx::Error.new("Santander MX service error (502). Please try again later.", failure_code: :server_error),
    "a network error after retries" => Provider::SantanderMx::Error.new("Network error after 3 retries: SocketError", failure_code: :network_error),
    "a raw timeout echoing the request" => Net::ReadTimeout.new("GET http://santander-host.invalid/transactions Bearer s3cret-xyz")
  }.each do |name, error|
    test "#{name} fails the import, leaves status and cursor alone and logs no token or URL" do
      item = SantanderMxItem.create!(
        family: families(:empty), name: "Leaky", base_url: "http://santander-host.invalid", api_token: "s3cret-xyz",
        transactions_synced_through: Date.new(2026, 11, 1)
      )
      @provider.stubs(:get_transactions).raises(error)

      result = SantanderMxItem::Importer.new(item, provider: @provider).import

      assert_equal false, result[:success]
      item.reload
      assert item.good?
      assert_equal Date.new(2026, 11, 1), item.transactions_synced_through
      logged = DebugLogEntry.where(provider_key: "santander_mx", family: item.family)
      assert_equal 1, logged.count
      assert_equal "error", logged.sole.level
      [ result[:error].to_s, logged.to_json ].each do |text|
        [ "s3cret-xyz", "santander-host.invalid" ].each { |secret| assert_not_includes text, secret }
      end
    end
  end

  test "last4 and currency come from the newest row whatever the response order" do
    old = row("o", "GOLD", "1111", currency: "USD").merge("date" => "2026-11-01")
    recent = row("n", "GOLD", "9999", currency: "MXN").merge("date" => "2026-11-10")

    [ [ recent, old ], [ old, recent ] ].each do |rows|
      @item.santander_mx_accounts.destroy_all
      @provider.stubs(:get_transactions).returns(response(rows))
      import

      gold = @item.santander_mx_accounts.find_by!(name: "GOLD")
      assert_equal "9999", gold.last4
      assert_equal "MXN", gold.currency
    end
  end

  test "a response containing only older rows replaces last4 because the stored value carries no date" do
    recent = row("n", "GOLD", "9999").merge("date" => "2026-11-10")
    old = row("o", "GOLD", "1111").merge("date" => "2026-11-01")
    @provider.stubs(:get_transactions).returns(response([ recent ]))
    import
    @provider.stubs(:get_transactions).returns(response([ old ]))
    import

    # Newest-row selection is per response; the stored last4 has no date, so the older row wins.
    assert_equal "1111", @item.santander_mx_accounts.find_by!(name: "GOLD").last4
  end

  test "blank values and unparsable dates never beat a usable value" do
    rows = [
      row("a", "GOLD", "5555").merge("date" => "not a date"),
      row("b", "GOLD", nil).merge("date" => "2026-11-10"),
      row("c", "GOLD", "4444").merge("date" => "2026-11-05")
    ]
    @provider.stubs(:get_transactions).returns(response(rows))
    import

    assert_equal "4444", @item.santander_mx_accounts.find_by!(name: "GOLD").last4

    @provider.stubs(:get_transactions).returns(response([ row("d", "GOLD", nil, currency: nil).merge("date" => "2026-11-12") ]))
    import
    gold = @item.santander_mx_accounts.find_by!(name: "GOLD")
    assert_equal "4444", gold.last4
    assert_equal "MXN", gold.currency
  end

  test "ties on date are won by the later row in the response" do
    rows = [ row("a", "GOLD", "1111").merge("date" => "2026-11-05"), row("b", "GOLD", "2222").merge("date" => "2026-11-05") ]
    @provider.stubs(:get_transactions).returns(response(rows))
    import

    assert_equal "2222", @item.santander_mx_accounts.find_by!(name: "GOLD").last4
  end

  test "a stored payload that is not a hash is replaced by the incoming rows" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))
    import
    gold = @item.santander_mx_accounts.find_by!(name: "GOLD")

    [ [ "x", 1 ], "junk", nil ].each do |junk|
      gold.update_columns(raw_transactions_payload: junk)
      assert import[:success], "payload #{junk.inspect}"
      assert_equal %w[a], gold.reload.raw_transactions_payload.keys
    end
  end

  test "invalid item attributes do not stop a 401 or 503 from requiring an update" do
    @item.update_columns(base_url: "ftp://x")
    [ Provider::SantanderMx::AuthenticationError.new("no", failure_code: :unauthorized),
      Provider::SantanderMx::ReauthorizationRequiredError.new("again", failure_code: :reauthorization_required) ].each do |error|
      @item.update_columns(status: "good")
      @provider.stubs(:get_transactions).raises(error)

      result = import

      assert_not result[:success]
      assert @item.reload.requires_update?
    end
  end

  test "invalid item attributes do not stop the success path" do
    @item.update_columns(base_url: "ftp://x", status: "requires_update")
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))

    travel_to Date.new(2026, 11, 15) do
      assert import[:success]
    end

    @item.reload
    assert_equal Date.new(2026, 11, 15), @item.transactions_synced_through
    assert @item.good?
  end

  test "import does not persist unrelated dirty attributes" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))
    @item.name = "Renamed"

    assert import[:success]

    assert_equal "Santander", SantanderMxItem.find(@item.id).name
  end

  test "stores rows under a row lock on the item" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { import }

    assert sql.any? { |q| q.include?("FOR UPDATE") && q.include?("santander_mx_items") }, "expected SELECT ... FOR UPDATE on the item"
  end

  test "rows another sync stored after the fetch are kept" do
    existing = @item.santander_mx_accounts.create!(name: "GOLD", raw_transactions_payload: { "p" => row("p", "GOLD", nil) })
    @provider.expects(:get_transactions).once.with do |**|
      existing.update_columns(raw_transactions_payload: { "p" => row("p", "GOLD", nil), "q" => row("q", "GOLD", nil) })
      true
    end.returns(response([ row("a", "GOLD", nil) ]))

    assert import[:success]
    assert_equal %w[a p q], existing.reload.raw_transactions_payload.keys.sort
  end

  test "the cursor is the date the fetch started, not the date it finished" do
    @provider.stubs(:get_transactions).with do |**|
      travel_to Date.new(2026, 11, 16)
      true
    end.returns(response)

    travel_to Date.new(2026, 11, 15) do
      assert import[:success]
      assert_equal Date.new(2026, 11, 15), @item.reload.transactions_synced_through
    end
  end

  test "product names are stored stripped so spacing variants are one product" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil), row("b", "GOLD ", nil), row("c", " GOLD", nil) ]))

    result = import

    assert_equal 1, result[:accounts_seen]
    assert_equal [ "GOLD" ], @item.santander_mx_accounts.pluck(:name)
    assert_equal %w[a b c], @item.santander_mx_accounts.first.raw_transactions_payload.keys.sort
  end

  test "a no-break space around a product name does not split the product" do
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil), row("b", "GOLD\u00A0", nil), row("c", "\u00A0GOLD", nil) ]))

    result = import

    assert_equal 1, result[:accounts_seen]
    assert_equal [ "GOLD" ], @item.santander_mx_accounts.pluck(:name)
    assert_equal %w[a b c], @item.santander_mx_accounts.first.raw_transactions_payload.keys.sort
  end

  test "a stored payload that is not a Hash is replaced even when its product gets no rows" do
    [ [ "x", 1 ], "junk" ].each do |junk|
      account = @item.santander_mx_accounts.create!(name: "SILENT#{junk.class}")
      account.update_column(:raw_transactions_payload, junk)
      @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", nil) ]))

      import

      assert_equal({}, account.reload.raw_transactions_payload)
    end
  end

  test "rows with a non-string account or an id that is not a string or integer are skipped and logged" do
    rows = [ row("a", 123, nil), row("b", { "x" => 1 }, nil), row({ "x" => 1 }, "GOLD", nil), row([ 1 ], "GOLD", nil), row("ok", "GOLD", nil) ]
    @provider.stubs(:get_transactions).returns(response(rows))

    result = import

    assert_equal 1, result[:transactions_seen]
    assert_equal %w[ok], @item.santander_mx_accounts.find_by!(name: "GOLD").raw_transactions_payload.keys
    assert_equal 1, DebugLogEntry.where(provider_key: "santander_mx", category: "provider_sync").count
  end

  test "an integer id and the same id as a string are one row" do
    @provider.stubs(:get_transactions).returns(response([ row(1, "GOLD", nil), row("1", "GOLD", nil, amount: "5.00") ]))

    result = import

    assert_equal 1, result[:transactions_seen]
    assert_equal "5.00", @item.santander_mx_accounts.find_by!(name: "GOLD").raw_transactions_payload["1"]["amount"]
  end

  test "a failure after accounts were created rolls everything back" do
    @item.update!(transactions_synced_through: Date.new(2026, 11, 1))
    @provider.stubs(:get_transactions).returns(response([ row("a", "GOLD", "1111"), row("b", "SANTANDER", nil) ], [ { "id" => "m1" } ]))
    DebugLogEntry.stubs(:capture).with { |**kw| kw[:message].to_s.include?("could not parse") }.raises("boom")
    DebugLogEntry.stubs(:capture).with { |**kw| !kw[:message].to_s.include?("could not parse") }.returns(nil)

    result = nil
    assert_no_difference -> { SantanderMxAccount.count } do
      result = import
    end

    assert_equal false, result[:success]
    @item.reload
    assert_equal Date.new(2026, 11, 1), @item.transactions_synced_through
    assert @item.good?
  end

  test "status returns to good after a 401 followed by a successful import" do
    @provider.stubs(:get_transactions).raises(Provider::SantanderMx::AuthenticationError.new("no", failure_code: :unauthorized))
    import
    assert @item.reload.requires_update?

    @provider.stubs(:get_transactions).returns(response)
    assert import[:success]
    assert @item.reload.good?
  end

  test "an unexpected error returns a neutral message" do
    @provider.stubs(:get_transactions).raises("boom")

    assert_equal I18n.t("santander_mx_item.errors.sync_failed"), import[:error]
    assert_no_match(/reach/, I18n.t("santander_mx_item.errors.sync_failed"))
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
