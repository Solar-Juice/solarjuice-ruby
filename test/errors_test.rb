# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    class ErrorsTest < TestCase
      # Every code in the spec's ErrorCode enumeration, with the status it is
      # documented against.
      CODE_TO_CLASS = {
        ["UNAUTHORIZED", 401] => UnauthorizedError,
        ["FORBIDDEN", 403] => ForbiddenError,
        ["NOT_FOUND", 404] => NotFoundError,
        ["VALIDATION_FAILED", 422] => ValidationFailedError,
        ["RATE_LIMITED", 429] => RateLimitedError,
        ["PRICE_CHANGED", 409] => PriceChangedError,
        ["IDEMPOTENCY_CONFLICT", 409] => IdempotencyConflictError,
        ["QUOTE_UNAVAILABLE", 503] => QuoteUnavailableError,
        ["STALE_DATA", 503] => StaleDataError,
        ["INTERNAL", 500] => InternalError
      }.freeze

      def test_maps_every_documented_error_code_to_its_class
        CODE_TO_CLASS.each do |(code, status), klass|
          # max_retries zero keeps the retryable statuses (429, 503) from
          # consuming extra queued responses.
          client = build_client(max_retries: 0)
          transport.enqueue_response(StubTransport.error_response(status, code))

          error = assert_raises(klass) { client.health }

          assert_equal code, error.code
          assert_equal status, error.status_code
          assert_kind_of ApiError, error
          assert_kind_of Error, error
        end
      end

      def test_carries_message_details_and_request_id
        client = build_client(max_retries: 0)
        details = [{ "field" => "lines[1].quantity", "message" => "must be between 1 and 9999" }]
        transport.enqueue(
          status: 422,
          body: {
            "error" => {
              "code" => "VALIDATION_FAILED",
              "message" => "Request body is invalid.",
              "details" => details,
              "request_id" => "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD"
            }
          }
        )

        error = assert_raises(ValidationFailedError) { client.health }

        assert_equal "Request body is invalid.", error.message
        assert_equal details, error.details
        assert_equal "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD", error.request_id
      end

      def test_rate_limited_carries_retry_after_when_the_header_is_present
        client = build_client(max_retries: 0)
        transport.enqueue(
          status: 429,
          headers: { "Retry-After" => "30" },
          body: { "error" => { "code" => "RATE_LIMITED", "message" => "slow down", "details" => [], "request_id" => "req_x" } }
        )

        error = assert_raises(RateLimitedError) { client.health }

        assert_equal 30, error.retry_after
      end

      def test_falls_back_to_the_status_when_the_body_is_not_the_documented_envelope
        client = build_client(max_retries: 0)
        transport.enqueue(status: 401, body: "<html>gateway says no</html>")

        error = assert_raises(UnauthorizedError) { client.health }

        assert_equal "UNAUTHORIZED", error.code
        assert_equal 401, error.status_code
        assert_empty error.details
      end

      def test_the_code_is_synthesised_from_the_status_when_there_is_no_envelope
        # An edge page or an empty body must not leave code nil, or a caller
        # branching on `e.code == "RATE_LIMITED"` silently falls through.
        {
          401 => "UNAUTHORIZED",
          403 => "FORBIDDEN",
          404 => "NOT_FOUND",
          422 => "VALIDATION_FAILED",
          429 => "RATE_LIMITED",
          500 => "INTERNAL"
        }.each do |status, code|
          client = build_client(max_retries: 0)
          transport.enqueue(status: status, body: "<html>edge page</html>")

          error = assert_raises(ApiError) { client.health }

          assert_equal code, error.code, "status #{status}"
          assert_equal status, error.status_code
        end
      end

      def test_a_rate_limited_edge_page_still_answers_to_the_documented_code
        client = build_client(max_retries: 0)
        transport.enqueue(status: 429, headers: { "Content-Type" => "text/html" }, body: "<html>429</html>")

        error = assert_raises(RateLimitedError) { client.health }

        assert_equal "RATE_LIMITED", error.code
      end

      def test_the_two_ambiguous_statuses_keep_a_nil_code
        # 409 and 503 each cover two documented codes, so with no envelope there
        # is nothing to choose between them.
        [409, 503].each do |status|
          client = build_client(max_retries: 0)
          transport.enqueue(status: status, body: nil)

          error = assert_raises(ApiError) { client.health }

          assert_nil error.code, "status #{status}"
          assert_instance_of ApiError, error
        end
      end

      def test_retry_after_is_on_every_api_error_not_only_the_rate_limited_one
        # The API sends Retry-After with 503 QUOTE_UNAVAILABLE as well, and the
        # Node and PHP clients both surface it there.
        client = build_client(max_retries: 0)
        transport.enqueue_response(
          StubTransport.error_response(503, "QUOTE_UNAVAILABLE", headers: { "Retry-After" => "2" })
        )

        error = assert_raises(QuoteUnavailableError) { client.health }

        assert_equal 2, error.retry_after
        assert_respond_to ApiError.new("any"), :retry_after
      end

      def test_retry_after_is_a_whole_number_of_seconds_from_the_date_form
        client = build_client(max_retries: 0)
        transport.enqueue(
          status: 429,
          headers: { "Retry-After" => (Time.now + 7).httpdate },
          body: nil
        )

        error = assert_raises(RateLimitedError) { client.health }

        # Rounded up, never a float: the other SDKs report 7 for this response.
        assert_instance_of Integer, error.retry_after
        assert_equal 7, error.retry_after
      end

      def test_retry_after_in_the_past_is_zero_not_a_negative_float
        client = build_client(max_retries: 0)
        transport.enqueue(status: 429, headers: { "Retry-After" => (Time.now - 30).httpdate }, body: nil)

        error = assert_raises(RateLimitedError) { client.health }

        assert_equal 0, error.retry_after
        assert_instance_of Integer, error.retry_after
      end

      def test_unknown_status_and_unknown_code_land_on_the_generic_api_error
        client = build_client(max_retries: 0)
        transport.enqueue(status: 418, body: nil)

        error = assert_raises(ApiError) { client.health }
        assert_equal 418, error.status_code

        client = build_client(max_retries: 0)
        transport.enqueue(
          status: 409,
          body: { "error" => { "code" => "SOMETHING_NEW", "message" => "future code", "details" => [], "request_id" => "req_x" } }
        )

        error = assert_raises(ApiError) { client.health }
        assert_equal "SOMETHING_NEW", error.code
        assert_equal "future code", error.message
      end

      def test_409_without_a_body_is_ambiguous_and_stays_generic
        client = build_client(max_retries: 0)
        transport.enqueue(status: 409, body: nil)

        error = assert_raises(ApiError) { client.health }

        assert_instance_of ApiError, error
        assert_equal 409, error.status_code
      end

      def test_network_failures_raise_a_transport_error
        client = build_client(max_retries: 0)
        transport.enqueue_error(TransportError.new("connection refused"))

        error = assert_raises(TransportError) { client.health }

        assert_kind_of Error, error
        assert_nil error.status_code
      end

      def test_timeouts_are_a_transport_error_subclass
        client = build_client(max_retries: 0)
        transport.enqueue_error(TimeoutError.new("timed out"))

        error = assert_raises(TimeoutError) { client.health }

        assert_kind_of TransportError, error
      end

      def test_a_success_with_a_body_that_is_not_json_is_reported_not_swallowed
        client = build_client
        transport.enqueue(status: 200, body: "not json at all")

        assert_raises(ApiError) { client.health }
      end

      def test_a_success_body_that_is_not_an_object_is_reported
        client = build_client
        transport.enqueue(status: 200, body: "[1, 2, 3]")

        assert_raises(ApiError) { client.health }
      end

      def test_an_empty_success_body_decodes_to_an_empty_result
        client = build_client
        transport.enqueue(status: 200, body: "")

        assert_empty client.health
      end
    end
  end
end
