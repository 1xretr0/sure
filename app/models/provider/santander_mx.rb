# frozen_string_literal: true

# Client for the separate santander-mx-gmail-parser service, which reads Santander MX
# notification emails from Gmail and exposes them as `GET /transactions?since=<iso>`.
#
# The bearer token only ever travels in the Authorization header. It must never reach an
# exception message, a log line or debug metadata, and neither may the response body
# (transaction PII); only the service's own `{"error": "<message>"}` text is surfaced.
class Provider::SantanderMx < Provider
  include HTTParty
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::SantanderMx::Error
  Error = Class.new(Provider::Error)
  # 401: the service rejected the credentials.
  class AuthenticationError < Error; end
  # 503: Gmail needs re-authorizing on the service host (or its API_TOKEN is unset).
  class ReauthorizationRequiredError < Error; end

  headers "User-Agent" => "Sure Finance Santander MX Client (https://github.com/we-promise/sure)"
  default_options.merge!({ timeout: 60 }.merge(httparty_ssl_options))

  RETRYABLE_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    EOFError
  ].freeze

  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2 # seconds

  OPERATION = "GET transactions"

  attr_reader :base_url, :api_token

  def initialize(base_url:, api_token:)
    @base_url = base_url.to_s.strip
    @api_token = api_token.to_s.strip

    if @base_url.blank? || @api_token.blank?
      raise Error.new("Santander MX base URL and API token are required", failure_code: :configuration_error)
    end
  end

  # @param since [Date] lower bound of the email window
  # @return [ActiveSupport::HashWithIndifferentAccess] with `transactions` and `unparsed` arrays
  def get_transactions(since:)
    body = with_retries(OPERATION) do
      response = self.class.get(
        "#{base_url.chomp('/')}/transactions",
        query: { since: since.iso8601 },
        headers: request_headers
      )
      handle_response(response)
    end

    transactions = body.is_a?(Hash) ? body["transactions"] : nil
    unparsed = body.is_a?(Hash) ? body.fetch("unparsed", []) : nil

    unless transactions.is_a?(Array) && unparsed.is_a?(Array)
      capture_request_error(level: "error", message: "Santander MX response had no transactions array", metadata: { status: 200 })
      raise Error.new("Unexpected Santander MX response", failure_code: :parse_error)
    end

    body.merge("unparsed" => unparsed).with_indifferent_access
  end

  private

    def request_headers
      { "Accept" => "application/json", "Authorization" => "Bearer #{api_token}" }
    end

    # Runs the block, retrying transient network errors with exponential backoff.
    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Santander MX API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}. Retrying in #{delay.round(2)}s..."
          )
          sleep(delay)
          retry
        end

        capture_request_error(
          level: "error",
          message: "Santander MX API request failed after retries",
          metadata: { error_class: e.class.name, retry_limit: max_retries }
        )
        raise Error.new("Network error after #{max_retries} retries: #{e.class}", failure_code: :network_error)
      end
    end

    # Exponential backoff delay (with jitter), capped at 30 seconds.
    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def handle_response(response)
      case response.code
      when 200
        parse_response_body(response)
      when 400
        message = service_message(response, "Santander MX rejected the request")
        # The service's validation text (e.g. "since is required") is short and PII-free;
        # the raw body is never logged.
        capture_request_error(
          level: "error",
          message: "Santander MX API rejected the request",
          metadata: { status: 400, service_error: message.truncate(200) }
        )
        raise Error.new(message, failure_code: :bad_request)
      when 401
        raise AuthenticationError.new("Santander MX service rejected the credentials", failure_code: :unauthorized)
      when 503
        raise ReauthorizationRequiredError.new(
          service_message(response, "Santander MX service needs Gmail re-authorization"),
          failure_code: :reauthorization_required
        )
      when 500..599
        raise Error.new("Santander MX service error (#{response.code}). Please try again later.", failure_code: :server_error)
      else
        capture_request_error(
          level: "error",
          message: "Santander MX API returned an unexpected response status",
          metadata: { status: response.code }
        )
        raise Error.new("Failed to fetch Santander MX data", failure_code: :fetch_failed)
      end
    end

    def parse_response_body(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      capture_request_error(
        level: "error",
        message: "Santander MX API response could not be parsed",
        metadata: { status: response.code }
      )
      raise Error.new("Failed to parse Santander MX API response", failure_code: :parse_error)
    end

    # The service answers errors with `{"error": "<message>"}`.
    def service_message(response, fallback)
      message = JSON.parse(response.body.to_s)["error"]
      message.is_a?(String) && message.present? ? message : fallback
    rescue JSON::ParserError, NoMethodError, TypeError
      fallback
    end

    def capture_request_error(level:, message:, metadata: {})
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "santander_mx",
        metadata: metadata.merge(operation: OPERATION)
      )
    end
end
