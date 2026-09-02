# frozen_string_literal: true

module SolarJuice
  module PartnerApi
    # Base of the whole hierarchy, so a caller who only wants "anything this gem
    # raised" can rescue SolarJuice::PartnerApi::Error and nothing else.
    class Error < StandardError
      # Machine readable code from the error envelope, nil for transport and
      # configuration failures.
      attr_reader :code

      # Array of hashes as returned in error.details, never nil.
      attr_reader :details

      # X-Request-Id of the failing response. Quote it to Solar Juice support.
      attr_reader :request_id

      # HTTP status, nil when no response was received.
      attr_reader :status_code

      def initialize(message, code: nil, details: nil, request_id: nil, status_code: nil)
        super(message)
        @code = code
        @details = details || []
        @request_id = request_id
        @status_code = status_code
      end
    end

    # The client could not be built, for example no API key was passed and
    # SOLARJUICE_API_KEY is not set.
    class ConfigurationError < Error; end

    # The request never produced an HTTP response: DNS, TCP, TLS or a timeout.
    # Separate from ApiError because there is nothing to inspect but the cause.
    class TransportError < Error; end

    # Connect or read timed out. Subclass of TransportError so that a caller who
    # does not care about the distinction still catches it.
    class TimeoutError < TransportError; end

    # Any error the API itself returned. The subclasses below map one to one
    # onto the spec's ErrorCode enumeration; ApiError itself is raised when the
    # code is one this version of the gem does not know, which the spec
    # explicitly allows ("open enumeration").
    class ApiError < Error
      # Whole seconds from Retry-After, or nil when the response carried none.
      # It sits on every API error rather than only on RateLimitedError because
      # the API sends the header with 503 QUOTE_UNAVAILABLE as well, and the
      # Node and PHP clients both surface it there.
      attr_reader :retry_after

      def initialize(message, retry_after: nil, **kwargs)
        super(message, **kwargs)
        @retry_after = retry_after
      end
    end

    class UnauthorizedError < ApiError; end
    class ForbiddenError < ApiError; end
    class NotFoundError < ApiError; end
    class ValidationFailedError < ApiError; end
    class PriceChangedError < ApiError; end
    class IdempotencyConflictError < ApiError; end
    class QuoteUnavailableError < ApiError; end
    class StaleDataError < ApiError; end
    class InternalError < ApiError; end

    # The key's allowance is spent. retry_after, inherited from ApiError, is
    # what the API asked for, so a caller who has exhausted max_retries knows
    # how long to wait.
    class RateLimitedError < ApiError; end

    # Maps error.code from the response body onto a class.
    ERROR_CLASSES_BY_CODE = {
      "UNAUTHORIZED" => UnauthorizedError,
      "FORBIDDEN" => ForbiddenError,
      "NOT_FOUND" => NotFoundError,
      "VALIDATION_FAILED" => ValidationFailedError,
      "RATE_LIMITED" => RateLimitedError,
      "PRICE_CHANGED" => PriceChangedError,
      "IDEMPOTENCY_CONFLICT" => IdempotencyConflictError,
      "QUOTE_UNAVAILABLE" => QuoteUnavailableError,
      "STALE_DATA" => StaleDataError,
      "INTERNAL" => InternalError
    }.freeze

    # The code to report when a response is not the documented envelope, for
    # example a proxy's own 502 HTML page. Without this, error.code is nil on
    # exactly the responses a caller branches on. 409 and 503 are deliberately
    # absent: each maps to two codes, so without a body there is nothing to
    # choose between them and nil is the honest answer.
    ERROR_CODES_BY_STATUS = {
      401 => "UNAUTHORIZED",
      403 => "FORBIDDEN",
      404 => "NOT_FOUND",
      422 => "VALIDATION_FAILED",
      429 => "RATE_LIMITED",
      500 => "INTERNAL"
    }.freeze

    # Derived from the codes above so the two cannot drift apart. A status with
    # no synthesised code lands on the generic ApiError.
    ERROR_CLASSES_BY_STATUS =
      ERROR_CODES_BY_STATUS.transform_values { |code| ERROR_CLASSES_BY_CODE.fetch(code) }.freeze
  end
end
