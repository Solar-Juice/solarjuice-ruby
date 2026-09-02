# frozen_string_literal: true

require "net/http"
require "openssl"
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
        Net::WriteTimeout
      ].freeze

      def initialize(timeout: 30)
        @timeout = timeout
        @connections = {}
        @mutex = Mutex.new
      end

      def call(request)
        uri = URI.parse(request.url)
        @mutex.synchronize do
          begin
            response = connection(uri).request(build_request(uri, request))
          rescue *TIMEOUT_ERRORS => e
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

      def connection(uri)
        key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        http = @connections[key]
        return http if http&.started?

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        http.start
        @connections[key] = http
      end

      def discard(uri)
        key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        http = @connections.delete(key)
        http.finish if http&.started?
      rescue IOError
        # Already closed at the other end; nothing to clean up.
        nil
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
