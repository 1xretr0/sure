require "test_helper"

class SantanderMxItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = santander_mx_items(:one)
    @santander_account = santander_mx_accounts(:gold)
    @import_result = { success: true, unparsed_count: 0 }
    SantanderMxItem.any_instance.stubs(:import_latest_santander_mx_data).returns(@import_result)
  end

  test "does not process unlinked products" do
    SantanderMxAccount::Transactions::Processor.any_instance.expects(:process).never

    sync = sync_item

    assert_equal 1, sync.sync_stats["unlinked_accounts"]
  end

  test "processes linked products and schedules their account syncs" do
    account = link_account
    SantanderMxAccount::Transactions::Processor.any_instance.expects(:process).once
      .returns({ success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [] })
    Account.any_instance.expects(:sync_later).with { |args| args[:parent_sync].present? }.once

    sync = sync_item

    assert_equal 1, sync.sync_stats["linked_accounts"]
    assert_equal 0, sync.sync_stats["unlinked_accounts"]
    assert_equal account, @santander_account.reload.current_account
  end

  test "records the unparsed count in sync stats" do
    @import_result[:unparsed_count] = 4

    assert_equal 4, sync_item.sync_stats["unparsed_count"]
  end

  test "fails the sync when the import fails" do
    SantanderMxItem.any_instance.stubs(:import_latest_santander_mx_data).returns({ success: false, error: "x" })

    error = assert_raises(SantanderMxItem::Syncer::SyncError) { sync_item }

    assert_match "x", error.message
  end

  test "fails the sync when a linked product cannot be processed" do
    link_account
    SantanderMxAccount::Transactions::Processor.any_instance.stubs(:process).raises("boom")

    assert_raises(SantanderMxItem::Syncer::SyncError) { sync_item }
  end

  test "one account failing to process does not stop the others and fails the sync with the stage" do
    payload = { "m1" => { "id" => "m1", "date" => "2026-11-03", "amount" => "50.00", "currency" => "MXN", "type" => "purchase", "description" => "STORE" } }
    @santander_account.update!(raw_transactions_payload: payload)
    other = @item.santander_mx_accounts.create!(name: "SANTANDER LIKEU", currency: "MXN", raw_transactions_payload: payload)
    link_account
    other_account = Account.create!(family: @item.family, name: "Likeu", accountable: CreditCard.new, balance: 0, currency: "MXN")
    AccountProvider.create!(account: other_account, provider: other)

    real = { @santander_account => SantanderMxAccount::Transactions::Processor.new(@santander_account),
             other => SantanderMxAccount::Transactions::Processor.new(other) }

    # process_accounts has no defined order, so each product takes a turn failing: in one of
    # the two runs the failing product is processed first, whichever way the rows come back.
    [ [ @santander_account, other ], [ other, @santander_account ] ].each do |failing_account, healthy_account|
      healthy_account.current_account.entries.destroy_all
      DebugLogEntry.where(provider_key: "santander_mx").delete_all
      failing = stub("failing processor")
      failing.stubs(:process).raises("boom")
      SantanderMxAccount::Transactions::Processor.stubs(:new).with(failing_account).returns(failing)
      SantanderMxAccount::Transactions::Processor.stubs(:new).with(healthy_account).returns(real[healthy_account])

      sync = Sync.create!(syncable: @item)
      error = assert_raises(SantanderMxItem::Syncer::SyncError) { SantanderMxItem::Syncer.new(@item.reload).perform_sync(sync) }

      assert_match "Santander MX account processing", error.message
      assert_equal [ "sync_error" ], error.sync_errors.map { |e| e[:category] }
      assert_equal 1, healthy_account.current_account.entries.count
      entry = DebugLogEntry.where(provider_key: "santander_mx", message: "Failed to process account").sole
      assert_equal failing_account.account_provider, entry.account_provider
      assert_equal @item.family, entry.family
      assert_not_includes entry.to_json, @item.api_token
      assert_not_includes entry.to_json, @item.base_url
    end
  end

  test "an unexpected error fails the sync with a neutral message and logs only its class" do
    SantanderMxItem.any_instance.stubs(:import_latest_santander_mx_data).raises(
      Errno::ECONNREFUSED.new("#{@item.base_url} Bearer #{@item.api_token}")
    )

    error = assert_raises(SantanderMxItem::Syncer::SafeSyncError) { sync_item }

    assert_equal I18n.t("santander_mx_item.errors.sync_failed"), error.message
    entry = DebugLogEntry.where(provider_key: "santander_mx", message: "Unexpected sync error").sole
    assert_equal "Errno::ECONNREFUSED", entry.metadata["error_class"]
    [ @item.api_token, @item.base_url ].each { |secret| assert_not_includes entry.to_json, secret }
  end

  test "importing without credentials fails without calling the service" do
    @item.stubs(:santander_mx_provider).returns(nil)
    SantanderMxItem.any_instance.unstub(:import_latest_santander_mx_data)
    SantanderMxItem::Importer.expects(:new).never

    result = @item.import_latest_santander_mx_data

    assert_equal false, result[:success]
    assert result[:error].present?
  end

  private

    def link_account
      Account.create!(
        family: @item.family, name: "Santander Gold", accountable: CreditCard.new, balance: 0, currency: "MXN"
      ).tap { |account| AccountProvider.create!(account: account, provider: @santander_account) }
    end

    def sync_item
      sync = Sync.create!(syncable: @item)
      SantanderMxItem::Syncer.new(@item.reload).perform_sync(sync)
      sync.reload
    end
end
