require "test_helper"

class SantanderMxItemTest < ActiveSupport::TestCase
  setup do
    @item = santander_mx_items(:one)
  end

  test "rejects a base_url that is not an absolute http(s) URL" do
    [ "parser:5000", "ftp://x", "http://" ].each do |url|
      @item.base_url = url
      assert_not @item.valid?, "expected #{url.inspect} to be invalid"
      assert @item.errors[:base_url].any?
    end
  end

  test "accepts http and https base URLs" do
    [ "http://parser:5000", "https://host/santander" ].each do |url|
      @item.base_url = url
      assert @item.valid?, "expected #{url.inspect} to be valid"
    end
  end

  test "requires an api_token on create" do
    item = families(:dylan_family).santander_mx_items.new(name: "Santander MX", base_url: "http://parser.test")
    assert_not item.valid?
    assert item.errors[:api_token].any?
  end

  test "is syncable unless scheduled for deletion" do
    assert_includes SantanderMxItem.syncable, @item

    @item.update!(scheduled_for_deletion: true)
    assert_not_includes SantanderMxItem.syncable, @item
  end

  test "counts linked and unlinked accounts" do
    assert_equal 1, @item.total_accounts_count
    assert_equal 0, @item.linked_accounts_count
    assert_equal 1, @item.unlinked_accounts_count

    santander_mx_accounts(:gold).ensure_account_provider!(accounts(:depository))
    @item.reload

    assert_equal 1, @item.linked_accounts_count
    assert_equal 0, @item.unlinked_accounts_count
    assert_equal 1, @item.total_accounts_count
  end

  test "process_accounts succeeds for a linked product whose stored payload is junk" do
    santander_account = santander_mx_accounts(:gold)
    santander_account.ensure_account_provider!(
      Account.create!(family: @item.family, name: "Gold", accountable: CreditCard.new, balance: 0, currency: "MXN")
    )
    santander_account.update_column(:raw_transactions_payload, [ "x", 1 ])

    results = @item.process_accounts

    assert_equal [ true ], results.map { |r| r[:success] }
    assert_equal 0, results.first[:result][:total]
  end

  test "creating an item through the family starts a sync with the default name" do
    family = families(:dylan_family)
    SantanderMxItem.any_instance.expects(:sync_later)

    item = family.create_santander_mx_item!(base_url: "http://parser.test", api_token: "t")

    assert_equal "Santander MX", item.name
  end

  test "import_latest_santander_mx_data reloads the item afterwards" do
    provider = mock("provider")
    provider.stubs(:get_transactions).with { |**| @item.name = "Dirty"; true }.returns({ "transactions" => [], "unparsed" => [] })
    @item.stubs(:santander_mx_provider).returns(provider)

    @item.import_latest_santander_mx_data

    assert_not @item.changed?
    assert_not_equal "Dirty", @item.name
  end

  test "import_latest_santander_mx_data returns the import result when the item row is gone" do
    item = families(:dylan_family).santander_mx_items.create!(name: "Gone", base_url: "http://parser.test", api_token: "t")
    provider = mock("provider")
    provider.stubs(:get_transactions).with { |**| SantanderMxItem.where(id: item.id).delete_all; true }.returns({ "transactions" => [], "unparsed" => [] })
    item.stubs(:santander_mx_provider).returns(provider)

    result = item.import_latest_santander_mx_data

    assert_equal false, result[:success]
  end
end
