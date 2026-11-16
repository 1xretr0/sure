require "test_helper"

class SantanderMxItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = santander_mx_items(:one)
    @santander_account = santander_mx_accounts(:gold)
    @import_result = { success: true, accounts_seen: 1, transactions_seen: 0, unparsed_count: 0 }
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
      ).tap { |account| @santander_account.ensure_account_provider!(account) }
    end

    def sync_item
      sync = Sync.create!(syncable: @item)
      SantanderMxItem::Syncer.new(@item.reload).perform_sync(sync)
      sync.reload
    end
end
