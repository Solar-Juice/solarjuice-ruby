# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/loopback_server"

module SolarJuice
  module PartnerApi
    class NetHttpTransportTest < TestCase
      def teardown
        @server&.stop
        @client&.close
      end

      def build_real_client(server, **options)
        @client = Client.new(
          api_key: TEST_KEY,
          base_url: server.base_url,
          sleeper: RecordingSleeper.new,
          **options
        )
      end

      def test_speaks_http_and_decodes_the_response
        @server = LoopbackServer.new
        client = build_real_client(@server)

        assert_equal({ "status" => "ok" }, client.health)
        assert_equal ["/v1/health"], @server.paths
        assert_equal "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD", client.last_request_id
        assert_equal 599, client.rate_limit.remaining
      end

      def test_reuses_one_connection_across_calls
        @server = LoopbackServer.new
        client = build_real_client(@server)

        3.times { client.health }

        assert_equal 3, @server.paths.size
        assert_equal 1, @server.connection_count, "the connection should be kept alive"
      end

      def test_reconnects_when_the_server_closed_an_idle_connection
        @server = LoopbackServer.new(mode: :once)
        client = build_real_client(@server)

        client.health
        assert_equal({ "status" => "ok" }, client.health)

        assert_equal 2, @server.connection_count
      end

      def test_a_refused_connection_is_a_transport_error
        server = LoopbackServer.new
        base_url = server.base_url
        server.stop # frees the port, so connecting to it is refused

        client = Client.new(api_key: TEST_KEY, base_url: base_url, max_retries: 0)

        assert_raises(TransportError) { client.health }
      end

      def test_a_silent_server_trips_the_read_timeout
        @server = LoopbackServer.new(mode: :hang)
        client = build_real_client(@server, timeout: 0.5, max_retries: 0)

        error = assert_raises(TimeoutError) { client.health }

        assert_kind_of TransportError, error
      end
    end
  end
end
