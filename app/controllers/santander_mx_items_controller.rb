# frozen_string_literal: true

# Connections are created, updated and removed from the providers settings panel
# (app/views/settings/providers/_santander_mx_panel.html.erb). The parser feed names the
# accounts, so there is no new-account flow: the only linking screen attaches a feed
# account to an existing Sure account. Nothing here ever logs or flashes the API token
# or the base URL.
class SantanderMxItemsController < ApplicationController
  before_action :set_santander_mx_item, only: [ :update, :destroy, :sync ]
  before_action :require_admin!, only: [
    :create, :update, :destroy, :sync, :select_existing_account, :link_existing_account
  ]

  # Create a connection and kick off its first sync.
  def create
    attributes = santander_mx_item_params
    token = attributes[:api_token].to_s.strip

    if token.blank?
      render_provider_panel("santander_mx", alert: t(".token_required"))
      return
    end

    Current.family.create_santander_mx_item!(
      base_url: attributes[:base_url].to_s.strip,
      api_token: token,
      item_name: attributes[:name].presence,
      sync_start_date: attributes[:sync_start_date].presence
    )

    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    render_provider_panel("santander_mx", alert: e.record.errors.full_messages.join(", "))
  end

  # Rename the connection, move its URL or start date, and/or rotate the token.
  def update
    attributes = update_params
    rotated_token = attributes[:api_token].present?
    # A rotated token is the fix for the failed authorization that set requires_update.
    attributes[:status] = :good if rotated_token && @santander_mx_item.requires_update?

    if @santander_mx_item.update(attributes)
      # Only a sync can find out whether the service accepts the new token.
      @santander_mx_item.sync_later if rotated_token && !@santander_mx_item.syncing?
      render_provider_panel("santander_mx", notice: t(".success"))
    else
      render_provider_panel("santander_mx", alert: @santander_mx_item.errors.full_messages.join(", "))
    end
  end

  # Unlink the accounts then schedule deletion of the connection.
  def destroy
    results = @santander_mx_item.unlink_all!(dry_run: false)

    if results.any? { |result| result[:error].present? }
      capture_destroy_failure(failures: results.select { |r| r[:error].present? })
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @santander_mx_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    capture_destroy_failure(error_class: e.class.name, error_message: e.message)
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  # Trigger a manual sync unless one is already running.
  def sync
    @santander_mx_item.sync_later unless @santander_mx_item.syncing?
    return render_provider_panel("santander_mx", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Offer the connection's unlinked feed accounts for attaching to an existing Sure account.
  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @santander_mx_item = requested_santander_mx_item
    unless @santander_mx_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @available_accounts = @santander_mx_item.santander_mx_accounts.unlinked.order(:name)
    @return_to = safe_return_to_path

    render layout: false
  end

  # Link a feed account to an existing Sure account and sync.
  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    santander_mx_item = requested_santander_mx_item

    unless santander_mx_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("santander_mx_items.select_existing_account.no_credentials_configured")
      return
    end

    santander_mx_account = santander_mx_item.santander_mx_accounts.find_by(id: params[:santander_mx_account_id])
    unless santander_mx_account
      redirect_to accounts_path, alert: t(".no_account_selected")
      return
    end

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if santander_mx_account.account_provider.present?
      redirect_to accounts_path, alert: t(".santander_mx_account_already_linked")
      return
    end

    unless Provider::SantanderMxAdapter.supported_account_types.include?(account.accountable_type)
      redirect_to accounts_path, alert: t(".unsupported_account_type")
      return
    end

    begin
      AccountProvider.create!(account: account, provider: santander_mx_account)
    rescue ActiveRecord::RecordNotUnique
      # A double submit gets past the reads above; the unique indexes settle it.
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    santander_mx_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  private

    def set_santander_mx_item
      @santander_mx_item = Current.family.santander_mx_items.find(params[:id])
    end

    def santander_mx_item_params
      params.require(:santander_mx_item).permit(:name, :base_url, :api_token, :sync_start_date)
    end

    # A blank token field keeps the token already on file.
    def update_params
      permitted = santander_mx_item_params
      token = permitted[:api_token].to_s.strip

      token.present? ? permitted.merge(api_token: token) : permitted.except(:api_token)
    end

    def requested_santander_mx_item
      Current.family.santander_mx_items.active.find_by!(id: params[:santander_mx_item_id])
    end

    # No token or URL in the metadata.
    def capture_destroy_failure(**metadata)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Santander MX unlink during destroy failed",
        source: self.class.name,
        provider_key: "santander_mx",
        family: @santander_mx_item&.family,
        metadata: { santander_mx_item_id: @santander_mx_item&.id, **metadata }
      )
    end

    # Validate the return_to param as a safe in-app relative path, or nil.
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")
      return nil if return_to[1] == "/" || return_to[1] == "\\"
      return nil if return_to.include?("\\") || return_to.match?(/[[:cntrl:]]/)
      return nil if encoded_path_separator?(return_to)

      uri = URI.parse(return_to)
      return nil unless uri.relative?

      Rails.application.routes.recognize_path(uri.path, method: :get)

      return_to
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end

    # True if the path's second char is a percent-encoded slash/backslash
    # (used to block protocol-relative redirect bypasses).
    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      true
    end
end
