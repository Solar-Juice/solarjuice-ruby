# frozen_string_literal: true

module SolarJuice
  module PartnerApi
    # The decoded JSON body, and nothing else, so partners can treat a response
    # as plain data: result["items"], result.dig("delivery", "suburb"),
    # JSON.generate(result) and == against a literal Hash all behave normally.
    #
    # It subclasses Hash rather than wrapping one because the few pieces of
    # response metadata the API puts in headers (the request id, the ETag, the
    # price list version, the idempotency key that was sent) have to reach the
    # caller somehow, and an accessor on the body is less friction than a second
    # return value on every method.
    class Result < ::Hash
      attr_accessor :request_id, :etag, :price_list_version, :idempotency_key, :status_code

      def self.from(body, response = nil)
        result = new
        result.merge!(body) if body.is_a?(::Hash)
        result.attach(response) if response
        result
      end

      def attach(response)
        @status_code = response.status
        @request_id = response.headers["x-request-id"]
        @etag = response.headers["etag"]
        @price_list_version = response.headers["x-price-list-version"]
        self
      end

      # False here and true on NotModified, so polling code can branch on one
      # predicate without checking classes.
      def not_modified?
        false
      end
    end

    # Returned instead of a body when the API answers 304 to an If-None-Match.
    # It is an empty Result, so a caller who ignores the distinction sees an
    # empty hash rather than an exception.
    class NotModified < Result
      def not_modified?
        true
      end
    end
  end
end
