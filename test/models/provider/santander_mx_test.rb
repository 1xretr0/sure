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

  test "never includes the token in an error message" do
    stub_response(401, { error: "unauthorized" }.to_json) do
      error = assert_raises(Provider::SantanderMx::AuthenticationError) { provider.get_transactions(since: Date.current) }
      assert_not_includes error.message, "tok"
    end
  end
end
