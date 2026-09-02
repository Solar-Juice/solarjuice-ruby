# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "json"
require "minitest/autorun"

require "solarjuice-partner-api"
require_relative "support/stub_transport"

module SolarJuice
  module PartnerApi
    # Base class for the suite: builds a client wired to a stub transport and a
    # recording sleeper, so no test touches the network or the clock.
    class TestCase < Minitest::Test
      # Key shaped like the real thing (sj_<env>_<keyid>_<32 hex>) but obviously
      # not one. Nothing in this suite leaves the process.
      TEST_KEY = "sj_test_aaaabbbbcccc_00000000000000000000000000000000"

      attr_reader :transport, :sleeper

      def build_client(**options)
        @transport = options.delete(:transport) || StubTransport.new
        @sleeper = options.delete(:sleeper) || RecordingSleeper.new

        Client.new(
          api_key: options.delete(:api_key) { TEST_KEY },
          transport: @transport,
          sleeper: @sleeper,
          **options
        )
      end

      # ENV is process wide, so anything that touches SOLARJUICE_API_KEY has to
      # put it back.
      def with_env(key, value)
        previous = ENV.key?(key)
        was = ENV[key]
        value.nil? ? ENV.delete(key) : ENV[key] = value
        yield
      ensure
        previous ? ENV[key] = was : ENV.delete(key)
      end

      def query_params(request)
        URI.parse(request.url).query.to_s.split("&").to_h { |pair| pair.split("=", 2) }
      end
    end
  end
end
