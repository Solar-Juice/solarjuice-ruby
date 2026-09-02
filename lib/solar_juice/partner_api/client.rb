# frozen_string_literal: true

require "json"
require "time"

require_relative "errors"
require_relative "net_http_transport"
require_relative "result"
require_relative "transport"
require_relative "util"
require_relative "version"
require_relative "resources/catalogue"
require_relative "resources/inventory"
require_relative "resources/orders"
require_relative "resources/shipping"
require_relative "resources/specials"

module SolarJuice
  module PartnerApi
    # The entry point. Build one per API key and keep it: it holds the HTTP
    # connection and the last seen rate limit state.
    #
    #   client = SolarJuice::PartnerApi::Client.new(api_key: ENV["SOLARJUICE_API_KEY"])
    #   client.catalogue.list(limit: 50)
    class Client
      DEFAULT_BASE_URL = "https://api.solarjuice.com.au"
      DEFAULT_TIMEOUT = 30
      DEFAULT_MAX_RETRIES = 3

      # 429 is retried because the API tells us when to come back; 502, 503 and
      # 504 because they are transient by definition. No other 4xx is retried:
      # the same request would fail the same way.
      RETRYABLE_STATUSES = [429, 502, 503, 504].freeze

      # Exponential backoff with full jitter: sleep a random slice of the window
      # so that a fleet of clients recovering from one outage does not come back
      # in lockstep.
      BACKOFF_BASE_SECONDS = 0.5
      BACKOFF_CAP_SECONDS = 8.0

      ENV_API_KEY = "SOLARJUICE_API_KEY"

      attr_reader :base_url, :timeout, :max_retries, :user_agent

      # Resource groups.
      attr_reader :catalogue, :inventory, :specials, :shipping, :orders

      # Rate limit state from the most recent response, or nil before the first
      # call. Values come from the RateLimit-Limit, RateLimit-Remaining and
      # RateLimit-Reset headers; reset is seconds until the window rolls over.
      attr_reader :rate_limit

      # X-Request-Id of the most recent response, error responses included.
      attr_reader :last_request_id

      # X-Price-List-Version from the most recent response that carried one.
      # Catalogue reads set it; submit it as price_list_version on an order.
      attr_reader :price_list_version

      RateLimit = Struct.new(:limit, :remaining, :reset)

      # api_key falls back to ENV["SOLARJUICE_API_KEY"].
      # user_agent is a suffix appended to solarjuice-ruby/<version>, not a
      # replacement, so Solar Juice can still see which SDK made the call.
      # transport is the injection point described in Transport.
      # sleeper exists so tests can assert on backoff without waiting for it.
      def initialize(api_key: nil,
                     base_url: nil,
                     timeout: DEFAULT_TIMEOUT,
                     max_retries: DEFAULT_MAX_RETRIES,
                     user_agent: nil,
                     transport: nil,
                     sleeper: nil)
        @api_key = api_key || ENV[ENV_API_KEY]
        if @api_key.nil? || @api_key.to_s.strip.empty?
          raise ConfigurationError.new(
            "No API key. Pass api_key: to SolarJuice::PartnerApi::Client.new or set #{ENV_API_KEY}."
          )
        end

        @base_url = (base_url || DEFAULT_BASE_URL).to_s.sub(%r{/+\z}, "")
        @timeout = timeout
        @max_retries = max_retries
        @user_agent = build_user_agent(user_agent)
        @transport = transport || NetHttpTransport.new(timeout: timeout)
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }

        @catalogue = Resources::Catalogue.new(self)
        @inventory = Resources::Inventory.new(self)
        @specials = Resources::Specials.new(self)
        @shipping = Resources::Shipping.new(self)
        @orders = Resources::Orders.new(self)
      end

      # GET /v1/health. Unauthenticated on the API side, but the key is sent
      # anyway so that every request out of this client looks the same.
      def health
        request(:get, "/v1/health")
      end

      # Low level escape hatch, also what every resource method calls. Use it
      # for an endpoint this version of the gem does not wrap yet.
      #
      # Returns a Result (the decoded body) or NotModified for a 304, and raises
      # an ApiError subclass for anything else outside 2xx.
      def request(method, path, query: nil, body: nil, headers: {})
        http_request = Transport::Request.new(
          method: method,
          url: build_url(path, query),
          headers: default_headers.merge(headers),
          body: body.nil? ? nil : JSON.generate(body)
        )

        response = send_with_retries(http_request)
        handle(response)
      end

      # Closes the underlying connection when the transport supports it.
      def close
        @transport.close if @transport.respond_to?(:close)
      end

      private

      def build_user_agent(suffix)
        base = "solarjuice-ruby/#{VERSION}"
        suffix.nil? || suffix.to_s.empty? ? base : "#{base} #{suffix}"
      end

      def default_headers
        {
          "Authorization" => "Bearer #{@api_key}",
          "Accept" => "application/json",
          "User-Agent" => @user_agent
        }
      end

      def build_url(path, query)
        encoded = Util.encode_query(query || {})
        url = "#{@base_url}#{path}"
        encoded ? "#{url}?#{encoded}" : url
      end

      def send_with_retries(http_request)
        attempt = 0

        loop do
          begin
            response = @transport.call(http_request)
          rescue TransportError
            raise if attempt >= @max_retries

            @sleeper.call(backoff_delay(attempt))
            attempt += 1
            next
          end

          record_response_metadata(response)

          if RETRYABLE_STATUSES.include?(response.status) && attempt < @max_retries
            # Retry-After is the API telling us exactly when it will serve us,
            # so it wins over the computed backoff.
            @sleeper.call(retry_after_seconds(response) || backoff_delay(attempt))
            attempt += 1
            next
          end

          return response
        end
      end

      def backoff_delay(attempt)
        window = [BACKOFF_BASE_SECONDS * (2**attempt), BACKOFF_CAP_SECONDS].min
        rand * window
      end

      # Retry-After is either a number of seconds or an HTTP date (RFC 9110).
      def retry_after_seconds(response)
        raw = response.headers["retry-after"]
        return nil if raw.nil? || raw.empty?

        return [raw.to_i, 0].max if raw.match?(/\A\d+\z/)

        begin
          [Time.httpdate(raw) - Time.now, 0].max
        rescue ArgumentError
          nil
        end
      end

      def record_response_metadata(response)
        headers = response.headers
        @last_request_id = headers["x-request-id"] if headers["x-request-id"]

        limit = headers["ratelimit-limit"]
        remaining = headers["ratelimit-remaining"]
        reset = headers["ratelimit-reset"]
        if limit || remaining || reset
          @rate_limit = RateLimit.new(limit&.to_i, remaining&.to_i, reset&.to_i)
        end

        version = headers["x-price-list-version"]
        @price_list_version = version if version
      end

      def handle(response)
        status = response.status

        # 304 is a successful conditional read, not a failure: the caller's
        # cached copy is still current.
        return NotModified.from(nil, response) if status == 304

        return Result.from(parse_body(response), response) if status >= 200 && status < 300

        raise build_error(response)
      end

      def parse_body(response)
        body = response.body
        return {} if body.nil? || body.empty?

        decoded = JSON.parse(body)
        return decoded if decoded.is_a?(Hash)

        # Every documented response is a JSON object. Anything else would be
        # silently dropped by Result, so say so instead.
        raise ApiError.new(
          "Expected a JSON object, got #{decoded.class}.",
          request_id: response.headers["x-request-id"],
          status_code: response.status
        )
      rescue JSON::ParserError
        # A 2xx that is not JSON is not worth guessing at, but the status and
        # request id are still useful, so surface it as an ApiError.
        raise ApiError.new(
          "Response body was not valid JSON.",
          request_id: response.headers["x-request-id"],
          status_code: response.status
        )
      end

      def build_error(response)
        envelope = begin
          parsed = response.body.nil? || response.body.empty? ? nil : JSON.parse(response.body)
          parsed.is_a?(Hash) ? parsed["error"] : nil
        rescue JSON::ParserError
          nil
        end

        code = envelope.is_a?(Hash) ? envelope["code"] : nil
        message = (envelope.is_a?(Hash) ? envelope["message"] : nil) ||
                  "HTTP #{response.status} from the Solar Juice Partner API."
        details = envelope.is_a?(Hash) ? envelope["details"] : nil
        request_id = (envelope.is_a?(Hash) ? envelope["request_id"] : nil) ||
                     response.headers["x-request-id"]

        klass = ERROR_CLASSES_BY_CODE[code] || ERROR_CLASSES_BY_STATUS[response.status] || ApiError
        kwargs = {
          code: code,
          details: details,
          request_id: request_id,
          status_code: response.status
        }
        kwargs[:retry_after] = retry_after_seconds(response) if klass == RateLimitedError

        klass.new(message, **kwargs)
      end
    end
  end
end
