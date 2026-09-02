# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    class ClientTest < TestCase
      def test_reads_the_api_key_from_the_environment
        with_env("SOLARJUICE_API_KEY", "sj_test_from_env") do
          transport = StubTransport.new(StubTransport.response(body: { "status" => "ok" }))
          Client.new(transport: transport).health

          assert_equal "Bearer sj_test_from_env", transport.last_request.headers["Authorization"]
        end
      end

      def test_an_explicit_key_beats_the_environment
        with_env("SOLARJUICE_API_KEY", "sj_test_from_env") do
          transport = StubTransport.new(StubTransport.response(body: {}))
          client = Client.new(api_key: "sj_test_explicit", transport: transport)
          client.health

          assert_equal "Bearer sj_test_explicit", transport.last_request.headers["Authorization"]
        end
      end

      def test_raises_a_configuration_error_when_there_is_no_key_anywhere
        with_env("SOLARJUICE_API_KEY", nil) do
          error = assert_raises(ConfigurationError) { Client.new }

          assert_kind_of Error, error
          assert_match(/SOLARJUICE_API_KEY/, error.message)
        end
      end

      def test_raises_a_configuration_error_for_a_blank_key
        with_env("SOLARJUICE_API_KEY", nil) do
          assert_raises(ConfigurationError) { Client.new(api_key: "   ") }
        end
      end

      def test_sends_the_documented_headers_on_every_request
        client = build_client
        transport.enqueue(body: {})
        client.health

        headers = transport.last_request.headers
        assert_equal "Bearer #{TEST_KEY}", headers["Authorization"]
        assert_equal "application/json", headers["Accept"]
        assert_equal "solarjuice-ruby/#{VERSION}", headers["User-Agent"]
      end

      def test_user_agent_option_is_a_suffix_not_a_replacement
        client = build_client(user_agent: "acme-storefront/2.1")
        transport.enqueue(body: {})
        client.health

        assert_equal "solarjuice-ruby/#{VERSION} acme-storefront/2.1", transport.last_request.headers["User-Agent"]
      end

      def test_defaults_to_the_production_base_url
        assert_equal "https://api.solarjuice.com.au", build_client.base_url
      end

      def test_base_url_override_drops_a_trailing_slash
        client = build_client(base_url: "https://staging.example.test/")
        transport.enqueue(body: {})
        client.health

        assert_equal "https://staging.example.test/v1/health", transport.last_request.url
      end

      def test_builds_query_strings_from_the_options_that_were_given
        client = build_client
        transport.enqueue(body: { "items" => [], "next_cursor" => nil })
        client.catalogue.list(limit: 50, brand: "GoodWe", updated_since: "2026-09-02T04:10:11Z")

        params = query_params(transport.last_request)
        assert_equal "50", params["limit"]
        assert_equal "GoodWe", params["brand"]
        assert_equal "2026-09-02T04%3A10%3A11Z", params["updated_since"]
        refute params.key?("category"), "unset options must not appear in the query"
        refute params.key?("cursor")
      end

      def test_encodes_booleans_as_strings
        client = build_client
        transport.enqueue(body: { "items" => [], "next_cursor" => nil })
        client.specials.list(active: true)

        assert_equal "true", query_params(transport.last_request)["active"]
      end

      def test_a_false_filter_is_sent_rather_than_dropped
        # Only nil means "not set": active: false is a real filter.
        client = build_client
        transport.enqueue(body: { "items" => [], "next_cursor" => nil })
        client.specials.list(active: false)

        assert_equal "false", query_params(transport.last_request)["active"]
      end

      def test_escapes_the_sku_in_the_path
        client = build_client
        transport.enqueue(body: { "sku" => "A/B C" })
        client.catalogue.get("A/B C")

        assert_equal "https://api.solarjuice.com.au/v1/catalogue/A%2FB%20C", transport.last_request.url
      end

      def test_returns_the_decoded_envelope_from_list
        client = build_client
        envelope = {
          "as_of" => "2026-09-02T04:10:11Z",
          "price_list_version" => "2026-09-02T04:00:00Z",
          "items" => [{ "sku" => "GW-5000-DNS-30" }],
          "next_cursor" => nil
        }
        transport.enqueue(body: envelope)

        page = client.catalogue.list

        assert_equal envelope, page
        assert_equal "GW-5000-DNS-30", page["items"].first["sku"]
      end

      def test_exposes_rate_limit_state_and_the_request_id
        client = build_client
        assert_nil client.rate_limit
        assert_nil client.last_request_id

        transport.enqueue(
          body: {},
          headers: {
            "RateLimit-Limit" => "600",
            "RateLimit-Remaining" => "12",
            "RateLimit-Reset" => "30",
            "X-Request-Id" => "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD"
          }
        )
        client.health

        assert_equal 600, client.rate_limit.limit
        assert_equal 12, client.rate_limit.remaining
        assert_equal 30, client.rate_limit.reset
        assert_equal "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD", client.last_request_id
      end

      def test_rate_limit_state_is_recorded_from_error_responses_too
        client = build_client
        transport.enqueue(
          status: 403,
          headers: { "RateLimit-Remaining" => "0" },
          body: { "error" => { "code" => "FORBIDDEN", "message" => "no", "details" => [], "request_id" => "req_x" } }
        )

        assert_raises(ForbiddenError) { client.health }
        assert_equal 0, client.rate_limit.remaining
      end

      def test_surfaces_the_price_list_version_from_catalogue_responses
        client = build_client
        transport.enqueue(
          body: { "sku" => "GW-5000-DNS-30" },
          headers: { "X-Price-List-Version" => "2026-09-02T04:00:00Z" }
        )

        product = client.catalogue.get("GW-5000-DNS-30")

        assert_equal "2026-09-02T04:00:00Z", product.price_list_version
        assert_equal "2026-09-02T04:00:00Z", client.price_list_version
      end

      def test_health_hits_the_documented_path
        client = build_client
        transport.enqueue(body: { "status" => "ok" })

        assert_equal({ "status" => "ok" }, client.health)
        assert_equal "https://api.solarjuice.com.au/v1/health", transport.last_request.url
        assert_equal :get, transport.last_request.method
      end

      def test_close_is_passed_to_the_transport
        client = build_client
        client.close

        assert transport.closed?
      end

      def test_inspect_never_prints_the_api_key
        client = build_client

        refute_includes client.inspect, TEST_KEY, "inspect would put the key in any debug log"
        assert_includes client.inspect, "https://api.solarjuice.com.au"
      end

      def test_pretty_print_never_prints_the_api_key
        require "pp"
        client = build_client
        printed = +""
        PP.pp(client, printed)

        refute_includes printed, TEST_KEY, "pp would put the key in a console session"
      end

      def test_no_instance_variable_holds_the_api_key
        # Covers every other way a key escapes: YAML.dump, a serialised job
        # payload, a crash reporter walking ivars.
        client = build_client
        held = client.instance_variables.map { |name| client.instance_variable_get(name).inspect }

        refute_includes held.join(" "), TEST_KEY
      end

      def test_rejects_a_timeout_that_is_not_a_positive_number
        [0, -1, "soon", nil, Float::INFINITY].each do |timeout|
          error = assert_raises(ConfigurationError, "timeout: #{timeout.inspect} should not build") do
            build_client(timeout: timeout)
          end

          assert_match(/timeout/, error.message)
        end
      end

      def test_accepts_a_fractional_timeout
        assert_in_delta 0.5, build_client(timeout: 0.5).timeout, 0.0001
      end

      def test_rejects_a_negative_or_non_integer_max_retries
        [-1, "lots", nil].each do |max_retries|
          error = assert_raises(ConfigurationError, "max_retries: #{max_retries.inspect} should not build") do
            build_client(max_retries: max_retries)
          end

          assert_match(/max_retries/, error.message)
        end
      end

      def test_accepts_zero_retries
        assert_equal 0, build_client(max_retries: 0).max_retries
      end

      def test_uuid_v4_generator_sets_the_version_and_variant_bits
        100.times do
          uuid = Util.uuid_v4
          assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, uuid)
        end
      end
    end
  end
end
