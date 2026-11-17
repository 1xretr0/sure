require "test_helper"

class SantanderMxItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @item = santander_mx_items(:one)
    @product = santander_mx_accounts(:gold)
  end

  test "create makes a connection and enqueues a sync" do
    SyncJob.expects(:perform_later).with { |sync| sync.syncable.is_a?(SantanderMxItem) }.once

    assert_difference "SantanderMxItem.count", 1 do
      post santander_mx_items_url, params: {
        santander_mx_item: {
          name: "Cards", base_url: "https://parser.example.com", api_token: " new-token ", sync_start_date: "2026-01-01"
        }
      }
    end

    assert_redirected_to settings_providers_path

    created = SantanderMxItem.order(:created_at).last
    assert_equal "new-token", created.api_token
    assert_equal "Cards", created.name
    assert_equal "https://parser.example.com", created.base_url
    assert_equal Date.new(2026, 1, 1), created.sync_start_date.to_date
  end

  test "create without a token shows an alert" do
    assert_no_difference "SantanderMxItem.count" do
      post santander_mx_items_url,
           params: { santander_mx_item: { name: "Cards", base_url: "https://parser.example.com", api_token: "  " } },
           as: :turbo_stream
    end

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "santander-mx-providers-panel"
    assert_includes response.body, ERB::Util.html_escape(I18n.t("santander_mx_items.create.token_required"))
  end

  test "create with an invalid url shows the validation error" do
    assert_no_difference "SantanderMxItem.count" do
      post santander_mx_items_url, params: {
        santander_mx_item: { name: "Cards", base_url: "not a url", api_token: "s3cret-xyz" }
      }
    end

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
    assert_not_includes flash[:alert], "s3cret-xyz"
  end

  test "a rejected create or update never echoes a submitted token into the re-rendered panel" do
    assert_no_difference "SantanderMxItem.count" do
      post santander_mx_items_url, params: {
        santander_mx_item: { name: "Cards", base_url: "not a url", api_token: "s3cret-xyz" }
      }, as: :turbo_stream
    end
    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "santander-mx-providers-panel"
    assert_not_includes response.body, "s3cret-xyz"

    patch santander_mx_item_url(@item), params: {
      santander_mx_item: { base_url: "not a url", api_token: "s3cret-rotated" }
    }, as: :turbo_stream
    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "santander-mx-providers-panel"
    [ "s3cret-rotated", "santander-test-token" ].each { |token| assert_not_includes response.body, token }
    assert_equal "http://parser.test", @item.reload.base_url
    assert_equal "santander-test-token", @item.api_token
  end

  test "update with a blank token keeps the stored token" do
    patch santander_mx_item_url(@item), params: {
      santander_mx_item: { name: "Renamed", base_url: "http://other.test", api_token: "" }
    }

    @item.reload
    assert_equal "Renamed", @item.name
    assert_equal "http://other.test", @item.base_url
    assert_equal "santander-test-token", @item.api_token
  end

  test "update with a new token clears requires_update" do
    @item.update!(status: :requires_update)
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @item }.once

    patch santander_mx_item_url(@item), params: {
      santander_mx_item: { name: @item.name, base_url: @item.base_url, api_token: "fresh-token" }
    }

    @item.reload
    assert_equal "fresh-token", @item.api_token
    assert @item.good?
  end

  test "update only syncs when the token is rotated" do
    SyncJob.expects(:perform_later).never

    patch santander_mx_item_url(@item), params: {
      santander_mx_item: { name: "Renamed", base_url: "http://other.test", sync_start_date: "2026-02-01", api_token: "" }
    }

    assert_equal "Renamed", @item.reload.name
  end

  test "update from the page re-renders the panel in place" do
    patch santander_mx_item_url(@item),
          params: { santander_mx_item: { name: "Renamed", api_token: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "santander-mx-providers-panel"
    assert_equal "Renamed", @item.reload.name
  end

  test "destroy unlinks accounts and schedules the connection for deletion" do
    @product.ensure_account_provider!(accounts(:depository))
    DestroyJob.expects(:perform_later).with(@item).once

    delete santander_mx_item_url(@item)

    assert_redirected_to settings_providers_path
    assert @item.reload.scheduled_for_deletion?
    assert_nil @product.reload.account_provider
  end

  test "sync enqueues a sync" do
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @item }.once

    post sync_santander_mx_item_url(@item)

    assert_redirected_to accounts_path
  end

  test "sync from the panel re-renders the panel in place" do
    post sync_santander_mx_item_url(@item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "santander-mx-providers-panel"
  end

  test "select_existing_account lists only unlinked products" do
    @item.santander_mx_accounts.create!(name: "SANTANDER PLATINUM", currency: "MXN")
    @product.ensure_account_provider!(accounts(:connected))

    get select_existing_account_santander_mx_items_url(
      santander_mx_item_id: @item.id, account_id: accounts(:depository).id
    )

    assert_response :success
    assert_includes response.body, "SANTANDER PLATINUM"
    assert_not_includes response.body, "SANTANDER GOLD"
  end

  test "link_existing_account links the product and syncs" do
    account = accounts(:depository)
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @item }.once

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_santander_mx_items_url, params: {
        santander_mx_item_id: @item.id, account_id: account.id, santander_mx_account_id: @product.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal account, @product.reload.current_account
  end

  test "link_existing_account refuses an account already linked" do
    other = santander_mx_accounts(:gold).dup.tap { |p| p.update!(name: "OTHER") }
    other.ensure_account_provider!(accounts(:depository))

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_santander_mx_items_url, params: {
        santander_mx_item_id: @item.id, account_id: accounts(:depository).id, santander_mx_account_id: @product.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("santander_mx_items.link_existing_account.account_already_linked"), flash[:alert]
  end

  test "link_existing_account refuses a product already linked" do
    @product.ensure_account_provider!(accounts(:connected))

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_santander_mx_items_url, params: {
        santander_mx_item_id: @item.id, account_id: accounts(:depository).id, santander_mx_account_id: @product.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("santander_mx_items.link_existing_account.santander_mx_account_already_linked"), flash[:alert]
  end

  test "link_existing_account refuses an unsupported account type" do
    assert_no_difference "AccountProvider.count" do
      post link_existing_account_santander_mx_items_url, params: {
        santander_mx_item_id: @item.id, account_id: accounts(:investment).id, santander_mx_account_id: @product.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("santander_mx_items.link_existing_account.unsupported_account_type"), flash[:alert]
  end

  test "cannot reach another family's connection" do
    foreign = families(:empty).create_santander_mx_item!(base_url: "http://x.test", api_token: "t")

    post sync_santander_mx_item_url(foreign)
    assert_response :not_found

    get select_existing_account_santander_mx_items_url(
      santander_mx_item_id: foreign.id, account_id: accounts(:depository).id
    )
    assert_response :not_found
  end

  test "non-admins are refused on every action and nothing changes" do
    sign_in users(:family_member)
    SyncJob.expects(:perform_later).never
    DestroyJob.expects(:perform_later).never
    original_name = @item.name
    account = accounts(:depository)

    assert_no_difference [ "SantanderMxItem.count", "AccountProvider.count" ] do
      post santander_mx_items_url, params: {
        santander_mx_item: { name: "Cards", base_url: "https://parser.example.com", api_token: "tok" }
      }
      assert_redirected_to accounts_path

      patch santander_mx_item_url(@item), params: { santander_mx_item: { name: "Renamed", api_token: "new" } }
      assert_redirected_to accounts_path

      delete santander_mx_item_url(@item)
      assert_redirected_to accounts_path

      post sync_santander_mx_item_url(@item)
      assert_redirected_to accounts_path

      get select_existing_account_santander_mx_items_url(santander_mx_item_id: @item.id, account_id: account.id)
      assert_redirected_to accounts_path

      post link_existing_account_santander_mx_items_url, params: {
        santander_mx_item_id: @item.id, account_id: account.id, santander_mx_account_id: @product.id
      }
      assert_redirected_to accounts_path
    end

    assert_equal I18n.t("shared.require_admin"), flash[:alert]
    @item.reload
    assert_equal original_name, @item.name
    assert_equal "santander-test-token", @item.api_token
    assert_not @item.scheduled_for_deletion?
    assert_nil @product.reload.account_provider
  end

  test "cannot use another family's account" do
    foreign_account = families(:empty).accounts.create!(
      name: "Foreign", balance: 0, currency: "MXN", accountable: Depository.new
    )

    get select_existing_account_santander_mx_items_url(
      santander_mx_item_id: @item.id, account_id: foreign_account.id
    )
    assert_response :not_found

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_santander_mx_items_url, params: {
        santander_mx_item_id: @item.id, account_id: foreign_account.id, santander_mx_account_id: @product.id
      }
    end
    assert_response :not_found
    assert_nil @product.reload.account_provider
  end

  test "the providers settings page renders the Santander panel without the stored token" do
    get settings_providers_path

    assert_response :success
    assert_includes response.body, "santander-mx-providers-panel"
    assert_not_includes response.body, "santander-test-token"
  end
end
