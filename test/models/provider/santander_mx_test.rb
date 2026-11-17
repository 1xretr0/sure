require "test_helper"

class Provider::SantanderMxTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  BODY = {
    since: "2026-11-01T00:00:00",
    until: "2026-11-15T00:00:00",
    transactions: [ { id: "abc", amount: "-10.00" } ],
    unparsed: []
  }.to_json

  def provider(base_url: "http://parser.test")
    Provider::SantanderMx.new(base_url: base_url, api_token: "tok")
  end

  def stub_response(code, body, &block)
    Provider::SantanderMx.stub(:get, ->(_url, query:, headers:) { FakeResponse.new(code: code, message: "", body: body) }, &block)
  end

  test "requests /transactions with since and the bearer token" do
    requests = []

    Provider::SantanderMx.stub(:get, ->(url, query:, headers:) {
      requests << { url: url, query: query, headers: headers }
      FakeResponse.new(code: 200, message: "OK", body: BODY)
    }) do
      result = provider.get_transactions(since: Date.new(2026, 11, 1))

      assert_equal "abc", result[:transactions].first["id"]
      assert_equal [], result[:unparsed]
    end

    request = requests.sole
    assert_equal "http://parser.test/transactions", request[:url]
    assert_equal({ since: "2026-11-01" }, request[:query])
    assert_equal "Bearer tok", request[:headers]["Authorization"]
  end

  test "joins the path onto a base_url with a trailing slash or a path prefix" do
    urls = []

    Provider::SantanderMx.stub(:get, ->(url, query:, headers:) {
      urls << url
      FakeResponse.new(code: 200, message: "OK", body: BODY)
    }) do
      provider(base_url: "http://parser.test/").get_transactions(since: Date.current)
      provider(base_url: "https://h/santander").get_transactions(since: Date.current)
    end

    assert_equal [ "http://parser.test/transactions", "https://h/santander/transactions" ], urls
  end

  test "normalize_base_url reduces a pasted URL to the service root" do
    {
      "https://h" => "https://h",
      "https://h/" => "https://h",
      "https://h///" => "https://h",
      "https://h/transactions" => "https://h",
      "https://h/transactions/" => "https://h",
      "https://h/Transactions//" => "https://h",
      "  https://h/santander/transactions \n" => "https://h/santander",
      "https://h/santander/" => "https://h/santander",
      "https://h/my-transactions" => "https://h/my-transactions",
      "https://h/a/transactions/b" => "https://h/a/transactions/b",
      "https://transactions" => "https://transactions",
      "" => "",
      nil => ""
    }.each do |input, expected|
      assert_equal expected, Provider::SantanderMx.normalize_base_url(input), "for #{input.inspect}"
    end
  end

  test "a base_url that already ends in /transactions is requested once, not doubled" do
    urls = []

    Provider::SantanderMx.stub(:get, ->(url, query:, headers:) {
      urls << url
      FakeResponse.new(code: 200, message: "OK", body: BODY)
    }) do
      provider(base_url: "https://h/santander/transactions").get_transactions(since: Date.current)
    end

    assert_equal [ "https://h/santander/transactions" ], urls
  end

  test "requires base_url and api_token" do
    [ { base_url: "", api_token: "tok" }, { base_url: "http://x", api_token: " " } ].each do |args|
      error = assert_raises(Provider::SantanderMx::Error) { Provider::SantanderMx.new(**args) }
      assert_equal :configuration_error, error.failure_code
    end
  end

  test "maps 401 to AuthenticationError" do
    stub_response(401, { error: "unauthorized" }.to_json) do
      assert_raises(Provider::SantanderMx::AuthenticationError) { provider.get_transactions(since: Date.current) }
    end
  end

  test "maps 503 to ReauthorizationRequiredError carrying the service message" do
    stub_response(503, { error: "Gmail token expired; re-authorize" }.to_json) do
      error = assert_raises(Provider::SantanderMx::ReauthorizationRequiredError) { provider.get_transactions(since: Date.current) }
      assert_equal "Gmail token expired; re-authorize", error.message
    end
  end

  test "maps 400 to Error with failure_code bad_request" do
    stub_response(400, { error: "since missing" }.to_json) do
      error = assert_raises(Provider::SantanderMx::Error) { provider.get_transactions(since: Date.current) }
      assert_equal :bad_request, error.failure_code
      assert_equal "since missing", error.message
    end
  end

  test "logs a 400 with the service error text and never the token" do
    captured = []
    DebugLogEntry.expects(:capture).once.with { |**args| captured << args }

    Provider::SantanderMx.stub(:get, ->(_url, query:, headers:) {
      FakeResponse.new(code: 400, message: "", body: { error: "since is required" }.to_json)
    }) do
      client = Provider::SantanderMx.new(base_url: "http://parser.test", api_token: "s3cret-xyz")
      assert_raises(Provider::SantanderMx::Error) { client.get_transactions(since: Date.current) }
    end

    entry = captured.sole
    assert_equal "santander_mx", entry[:provider_key]
    assert_equal "error", entry[:level]
    assert_equal 400, entry[:metadata][:status]
    assert_equal "since is required", entry[:metadata][:service_error]
    assert_not_includes entry.to_s, "s3cret-xyz"
  end

  test "maps 502 and other 5xx to Error with failure_code server_error" do
    [ 502, 500 ].each do |status|
      stub_response(status, { error: "gmail failure" }.to_json) do
        error = assert_raises(Provider::SantanderMx::Error) { provider.get_transactions(since: Date.current) }
        assert_equal :server_error, error.failure_code
      end
    end
  end

  test "raises parse_error when transactions is not an array" do
    stub_response(200, { transactions: {} }.to_json) do
      error = assert_raises(Provider::SantanderMx::Error) { provider.get_transactions(since: Date.current) }
      assert_equal :parse_error, error.failure_code
    end
  end

  test "raises parse_error when the body is not JSON" do
    stub_response(200, "<html>") do
      error = assert_raises(Provider::SantanderMx::Error) { provider.get_transactions(since: Date.current) }
      assert_equal :parse_error, error.failure_code
    end
  end

  test "retries a network error then raises network_error" do
    calls = 0
    client = provider
    client.stubs(:sleep)

    Provider::SantanderMx.stub(:get, ->(_url, query:, headers:) { calls += 1; raise Errno::ECONNREFUSED }) do
      error = assert_raises(Provider::SantanderMx::Error) { client.get_transactions(since: Date.current) }
      assert_equal :network_error, error.failure_code
    end

    assert_equal 4, calls
  end

  # Token, host and a payload marker that must never reach an exception message, a
  # DebugLogEntry or the Rails log, whichever way the request fails.
  SECRET = "s3cret-xyz"
  HOST = "http://parser-host.invalid"
  PII = "PII-CARD-4111"

  def leaks_after_failure(expected_error, status: nil, body: nil, raises: nil)
    captured = []
    log = StringIO.new
    Rails.stubs(:logger).returns(Logger.new(log))
    DebugLogEntry.stubs(:capture).with { |**args| captured << args }
    client = Provider::SantanderMx.new(base_url: HOST, api_token: SECRET)
    client.stubs(:sleep)

    Provider::SantanderMx.stub(:get, ->(_url, query:, headers:) {
      raise raises if raises
      FakeResponse.new(code: status, message: "", body: body)
    }) do
      error = assert_raises(expected_error) { client.get_transactions(since: Date.current) }

      [ [ "exception message", error.message ], [ "DebugLogEntry arguments", captured.to_s ], [ "Rails log", log.string ] ].each do |where, text|
        [ SECRET, HOST, URI(HOST).host, PII ].each { |value| assert_not_includes text, value, "#{value} leaked into the #{where}" }
      end
      error
    end
  end

  test "a 401 leaks neither the token nor the URL" do
    leaks_after_failure(Provider::SantanderMx::AuthenticationError, status: 401, body: { error: "unauthorized", detail: PII }.to_json)
  end

  test "a 503 surfaces the service text only" do
    error = leaks_after_failure(
      Provider::SantanderMx::ReauthorizationRequiredError, status: 503, body: { error: "re-authorize Gmail", detail: PII }.to_json
    )
    assert_equal "re-authorize Gmail", error.message
  end

  test "a 400 logs the service text only" do
    leaks_after_failure(Provider::SantanderMx::Error, status: 400, body: { error: "since is required", detail: PII }.to_json)
  end

  test "a 502 leaks nothing from the response" do
    leaks_after_failure(Provider::SantanderMx::Error, status: 502, body: { error: "gmail failure", detail: PII }.to_json)
  end

  test "a body that cannot be parsed leaks nothing" do
    leaks_after_failure(Provider::SantanderMx::Error, status: 200, body: "<html>#{PII} #{SECRET}</html>")
  end

  test "a network error echoing the request keeps only its class" do
    error = leaks_after_failure(Provider::SantanderMx::Error, raises: SocketError.new("getaddrinfo #{HOST} #{SECRET}"))
    assert_equal :network_error, error.failure_code
  end

  test "does not follow redirects so the bearer token cannot leave the configured host" do
    assert_equal true, Provider::SantanderMx.default_options[:no_follow]

    stub_response(302, "") do
      error = assert_raises(Provider::SantanderMx::Error) { provider.get_transactions(since: Date.current) }
      assert_equal :fetch_failed, error.failure_code
    end
  end
end
