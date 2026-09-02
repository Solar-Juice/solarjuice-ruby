# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    class RetriesTest < TestCase
      def test_retries_every_documented_retryable_status_then_succeeds
        Client::RETRYABLE_STATUSES.each do |status|
          client = build_client
          transport.enqueue_response(StubTransport.error_response(status, "INTERNAL"))
          transport.enqueue(body: { "status" => "ok" })

          assert_equal({ "status" => "ok" }, client.health, "status #{status} should be retried")
          assert_equal 2, transport.requests.size
          assert_equal 1, sleeper.delays.size
        end
      end

      def test_retries_network_failures
        client = build_client
        transport.enqueue_error(TransportError.new("connection reset"))
        transport.enqueue_error(TimeoutError.new("read timed out"))
        transport.enqueue(body: { "status" => "ok" })

        assert_equal({ "status" => "ok" }, client.health)
        assert_equal 3, transport.requests.size
      end

      def test_never_exceeds_max_retries
        client = build_client(max_retries: 2)
        4.times { transport.enqueue_response(StubTransport.error_response(503, "STALE_DATA")) }

        assert_raises(StaleDataError) { client.health }

        assert_equal 3, transport.requests.size, "one attempt plus two retries"
        assert_equal 2, sleeper.delays.size
      end

      def test_max_retries_zero_means_one_attempt
        client = build_client(max_retries: 0)
        transport.enqueue_error(TransportError.new("connection reset"))

        assert_raises(TransportError) { client.health }

        assert_equal 1, transport.requests.size
        assert_empty sleeper.delays
      end

      def test_does_not_retry_other_four_hundreds
        [400, 401, 403, 404, 409, 422].each do |status|
          client = build_client
          transport.enqueue_response(StubTransport.error_response(status, "VALIDATION_FAILED"))

          assert_raises(ApiError) { client.health }
          assert_equal 1, transport.requests.size, "status #{status} must not be retried"
        end
      end

      def test_does_not_retry_a_plain_five_hundred
        # 500 means the request itself broke something; 502, 503 and 504 are the
        # transient ones worth another attempt.
        client = build_client
        transport.enqueue_response(StubTransport.error_response(500, "INTERNAL"))

        assert_raises(InternalError) { client.health }
        assert_equal 1, transport.requests.size
      end

      def test_backoff_is_exponential_with_full_jitter_and_a_cap
        client = build_client(max_retries: 8)
        9.times { transport.enqueue_response(StubTransport.error_response(502, "INTERNAL")) }

        assert_raises(ApiError) { client.health }

        sleeper.delays.each_with_index do |delay, attempt|
          window = [Client::BACKOFF_BASE_SECONDS * (2**attempt), Client::BACKOFF_CAP_SECONDS].min
          assert_operator delay, :>=, 0
          assert_operator delay, :<=, window
        end
        assert_operator sleeper.delays.last, :<=, Client::BACKOFF_CAP_SECONDS
      end

      def test_retry_after_in_seconds_wins_over_the_computed_backoff
        client = build_client
        transport.enqueue_response(
          StubTransport.error_response(429, "RATE_LIMITED", headers: { "Retry-After" => "7" })
        )
        transport.enqueue(body: { "status" => "ok" })

        client.health

        assert_equal [7], sleeper.delays
      end

      def test_retry_after_as_an_http_date_is_honoured
        client = build_client
        future = (Time.now + 12).httpdate
        transport.enqueue_response(
          StubTransport.error_response(503, "QUOTE_UNAVAILABLE", headers: { "Retry-After" => future })
        )
        transport.enqueue(body: { "status" => "ok" })

        client.health

        assert_in_delta 12, sleeper.delays.first, 2
      end

      def test_a_retry_after_in_the_past_does_not_produce_a_negative_sleep
        client = build_client
        past = (Time.now - 60).httpdate
        transport.enqueue_response(
          StubTransport.error_response(503, "STALE_DATA", headers: { "Retry-After" => past })
        )
        transport.enqueue(body: { "status" => "ok" })

        client.health

        assert_equal [0], sleeper.delays
      end

      def test_an_unparseable_retry_after_falls_back_to_the_backoff
        client = build_client
        transport.enqueue_response(
          StubTransport.error_response(503, "STALE_DATA", headers: { "Retry-After" => "soon" })
        )
        transport.enqueue(body: { "status" => "ok" })

        client.health

        assert_equal 1, sleeper.delays.size
        assert_operator sleeper.delays.first, :<=, Client::BACKOFF_BASE_SECONDS
      end

      def test_a_retry_after_beyond_the_cap_is_not_slept
        # An edge proxy is not bound by the API's own small values, and parking
        # a worker for an hour is worse than failing.
        client = build_client
        transport.enqueue_response(
          StubTransport.error_response(429, "RATE_LIMITED", headers: { "Retry-After" => "3600" })
        )

        error = assert_raises(RateLimitedError) { client.health }

        assert_empty sleeper.delays
        assert_equal 1, transport.requests.size
        assert_equal 3600, error.retry_after, "the real value still reaches the caller"
      end

      def test_a_retry_after_at_the_cap_is_still_honoured
        client = build_client
        transport.enqueue_response(
          StubTransport.error_response(503, "STALE_DATA",
                                       headers: { "Retry-After" => Client::RETRY_AFTER_CAP_SECONDS.to_s })
        )
        transport.enqueue(body: { "status" => "ok" })

        client.health

        assert_equal [Client::RETRY_AFTER_CAP_SECONDS], sleeper.delays
      end

      def test_a_retry_after_date_beyond_the_cap_is_not_slept_either
        client = build_client
        transport.enqueue_response(
          StubTransport.error_response(503, "QUOTE_UNAVAILABLE",
                                       headers: { "Retry-After" => (Time.now + 900).httpdate })
        )

        assert_raises(QuoteUnavailableError) { client.health }

        assert_empty sleeper.delays
        assert_equal 1, transport.requests.size
      end

      def test_a_retried_post_keeps_its_idempotency_key
        # The whole reason POST /v1/orders is safe to retry: the second attempt
        # must carry the same key as the first.
        client = build_client
        transport.enqueue_response(StubTransport.error_response(503, "STALE_DATA"))
        transport.enqueue(status: 202, body: { "id" => "ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD" })

        client.orders.create({ "client_reference" => "PO-88213" })

        keys = transport.requests.map { |request| request.headers["Idempotency-Key"] }
        assert_equal 2, keys.size
        assert_equal keys.first, keys.last
      end
    end
  end
end
