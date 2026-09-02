# frozen_string_literal: true

module SolarJuice
  module PartnerApi
    # A transport that answers from a queue instead of a socket, so the whole
    # suite runs with no network. Queue an Exception to simulate a connection
    # failure or a timeout.
    class StubTransport
      attr_reader :requests

      def initialize(*responses)
        @responses = responses.flatten
        @requests = []
        @closed = false
      end

      def enqueue(status: 200, headers: {}, body: nil)
        @responses << self.class.response(status: status, headers: headers, body: body)
        self
      end

      # Queues a response built by one of the class helpers below.
      def enqueue_response(response)
        @responses << response
        self
      end

      def enqueue_error(error)
        @responses << error
        self
      end

      def call(request)
        @requests << request
        raise "StubTransport ran out of queued responses (request #{@requests.size})" if @responses.empty?

        queued = @responses.shift
        raise queued if queued.is_a?(Exception)

        queued
      end

      def close
        @closed = true
      end

      def closed?
        @closed
      end

      def last_request
        @requests.last
      end

      # Builds a JSON response with the headers every real response carries, so
      # a test only has to name the ones it cares about.
      def self.response(status: 200, headers: {}, body: nil)
        payload = body.is_a?(String) || body.nil? ? body : JSON.generate(body)
        defaults = {
          "Content-Type" => "application/json",
          "X-Request-Id" => "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD",
          "RateLimit-Limit" => "600",
          "RateLimit-Remaining" => "597",
          "RateLimit-Reset" => "42"
        }
        Transport::Response.new(status: status, headers: defaults.merge(headers), body: payload)
      end

      # The documented error envelope, which is what error mapping reads.
      def self.error_response(status, code, message: "Something went wrong.", details: [], headers: {})
        response(
          status: status,
          headers: headers,
          body: {
            "error" => {
              "code" => code,
              "message" => message,
              "details" => details,
              "request_id" => "req_01J6ZK3M5X8QW2R7Y9V4B1N0PD"
            }
          }
        )
      end
    end

    # Records what the client would have slept for instead of sleeping, so the
    # retry tests assert on backoff without taking seconds to run.
    class RecordingSleeper
      attr_reader :delays

      def initialize
        @delays = []
      end

      def call(seconds)
        @delays << seconds
      end
    end
  end
end
