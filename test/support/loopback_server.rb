# frozen_string_literal: true

require "socket"

module SolarJuice
  module PartnerApi
    # A minimal HTTP/1.1 server on a loopback port, used only by the transport
    # test. Everything else in the suite runs against StubTransport; this exists
    # so the one component that really does speak HTTP is exercised as it ships,
    # including connection reuse, without reaching outside the machine.
    class LoopbackServer
      RESPONSE_BODY = '{"status":"ok"}'

      # :ok    answer every request on the connection
      # :once  answer one request then close, as a keep-alive timeout would
      # :hang  accept and never answer, to trip the read timeout
      def initialize(mode: :ok)
        @mode = mode
        @server = TCPServer.new("127.0.0.1", 0)
        @connection_count = 0
        @paths = []
        @mutex = Mutex.new
        @thread = Thread.new { serve }
      end

      def base_url
        "http://127.0.0.1:#{@server.addr[1]}"
      end

      def connection_count
        @mutex.synchronize { @connection_count }
      end

      def paths
        @mutex.synchronize { @paths.dup }
      end

      def stop
        @thread&.kill
        @server.close unless @server.closed?
      rescue IOError
        nil
      end

      private

      def serve
        loop do
          connection = @server.accept
          @mutex.synchronize { @connection_count += 1 }
          Thread.new { handle(connection) }
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def handle(connection)
        loop do
          request_line = connection.gets
          break if request_line.nil?

          # Drain the headers. Only GETs are sent here, so there is no body.
          while (line = connection.gets) && line != "\r\n"; end

          @mutex.synchronize { @paths << request_line.split(" ")[1] }

          break if @mode == :close
          sleep if @mode == :hang

          connection.write(
            "HTTP/1.1 200 OK\r\n" \
            "Content-Type: application/json\r\n" \
            "X-Request-Id: req_01J6ZK3M5X8QW2R7Y9V4B1N0PD\r\n" \
            "RateLimit-Remaining: 599\r\n" \
            "Content-Length: #{RESPONSE_BODY.bytesize}\r\n\r\n#{RESPONSE_BODY}"
          )

          break if @mode == :once
        end

        connection.close
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        nil
      end
    end
  end
end
