# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "uri"

require_relative "errors"
require_relative "transport"

module SolarJuice
  module PartnerApi
    # The default transport: Net::HTTP from the standard library, with the
    # connection kept open between calls so a sync loop paging through the
    # catalogue does not pay for a TLS handshake per page.
    #
    # One connection is held per origin and calls are serialised on a mutex,
    # because a single Net::HTTP object cannot carry two requests at once. That
    # is the right trade for the usual case (one client, one thread, many
    # sequential requests). For parallel work, build one client per thread.
    class NetHttpTransport
      # Raised when the deadline passes part way through an exchange. Private:
      # #call turns it into the public TimeoutError before it escapes.
      class DeadlineExceeded < StandardError; end
      private_constant :DeadlineExceeded

      # Everything Net::HTTP can raise once the request is on its way. Any of
      # these means "no response", which is what the client retries on.
      NETWORK_ERRORS = [
        IOError,
        EOFError,
        SocketError,
        SystemCallError,
        OpenSSL::SSL::SSLError,
        Net::HTTPBadResponse,
        Net::ProtocolError
      ].freeze

      TIMEOUT_ERRORS = [
        Net::OpenTimeout,
        Net::ReadTimeout,
        Net::WriteTimeout,
        DeadlineExceeded
      ].freeze

      def initialize(timeout: 30)
        @timeout = timeout
        @connections = {}
        @mutex = Mutex.new
      end

      # timeout is the deadline for the whole exchange, not for one read of it.
      # Net::HTTP's own read_timeout restarts on every chunk that arrives, so a
      # server dribbling a byte at a time would hold the call open for as long
      # as it liked. Two things stop that: the socket timeouts are set to what
      # is left of the budget, and the exchange runs under a single deadline
      # that covers connect, headers and body alike.
      def call(request)
        uri = URI.parse(request.url)
        deadline = monotonic_now + @timeout

        @mutex.synchronize do
          response =
            begin
              Timeout.timeout(@timeout, DeadlineExceeded, "the #{@timeout}s deadline passed") do
                connection(uri, deadline).request(build_request(uri, request))
              end
            rescue *TIMEOUT_ERRORS => e
              # The socket is mid response and its state is unknown, so it goes
              # rather than being handed to the next call.
              discard(uri)
              raise TimeoutError.new("Request to #{uri.host} timed out after #{@timeout}s: #{e.message}")
            rescue *NETWORK_ERRORS => e
              # A keep-alive socket the server closed while idle surfaces here as
              # an EOFError. Dropping the connection means the client's retry gets
              # a fresh one instead of failing again on the same dead socket.
              discard(uri)
              raise TransportError.new("Request to #{uri.host} failed: #{e.class}: #{e.message}")
            end

          Transport::Response.new(
            status: response.code.to_i,
            headers: response.to_hash,
            body: response.body
          )
        end
      end

      # Closes every pooled connection. Optional: the sockets are released when
      # the transport is garbage collected, but long lived processes that build
      # clients on the fly should call it.
      def close
        @mutex.synchronize do
          @connections.each_value { |http| http.finish if http.started? }
          @connections.clear
        end
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Seconds left on this request's budget, and the point at which a stalled
      # exchange gives up.
      def remaining(deadline)
        left = deadline - monotonic_now
        raise DeadlineExceeded, "the #{@timeout}s deadline passed" unless left.positive?

        left
      end

      def connection(uri, deadline)
        key = connection_key(uri)
        http = @connections[key]

        unless http&.started?
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          # Connecting spends the same budget as the rest of the exchange.
          http.open_timeout = remaining(deadline)
          http.start
          @connections[key] = http
        end

        # Set on every call, reused connections included: the deadline belongs
        # to this request, and the socket is still carrying whatever the last
        # one left on it.
        left = remaining(deadline)
        http.read_timeout = left
        http.write_timeout = left
        http
      end

      def discard(uri)
        http = @connections.delete(connection_key(uri))
        http.finish if http&.started?
      rescue IOError
        # Already closed at the other end; nothing to clean up.
        nil
      end

      def connection_key(uri)
        "#{uri.scheme}://#{uri.host}:#{uri.port}"
      end

      def build_request(uri, request)
        path = uri.request_uri
        net_request =
          case request.method
          when :get then Net::HTTP::Get.new(path)
          when :post then Net::HTTP::Post.new(path)
          else raise ArgumentError, "Unsupported HTTP method: #{request.method}"
          end

        request.headers.each { |name, value| net_request[name] = value }
        net_request.body = request.body if request.body
        net_request
      end
    end
  end
end
