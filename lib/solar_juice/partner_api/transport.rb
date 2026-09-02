# frozen_string_literal: true

module SolarJuice
  module PartnerApi
    # The seam between the client and the network. A transport is anything that
    # responds to #call(Transport::Request) and returns a Transport::Response,
    # raising TransportError (or TimeoutError) when no response was received.
    #
    # Pass your own with Client.new(transport:) to test without a network, to
    # route through an instrumented HTTP stack, or to replay recorded traffic.
    module Transport
      # method is :get or :post, url is absolute, headers is a plain hash of
      # strings and body is a JSON string or nil.
      Request = Struct.new(:method, :url, :headers, :body, keyword_init: true)

      # status is an Integer, headers a Headers, body the raw response string.
      Response = Struct.new(:status, :headers, :body, keyword_init: true) do
        def initialize(status:, headers: nil, body: nil)
          super(status: status, headers: Headers.new(headers), body: body)
        end
      end

      # Case insensitive header lookup. HTTP header names are case insensitive
      # and different stacks hand them back in different cases, so the client
      # only ever reads them through here, always in lower case.
      class Headers
        include Enumerable

        def initialize(pairs = nil)
          @entries = {}
          return if pairs.nil?

          pairs.each do |name, value|
            @entries[name.to_s.downcase] = value.is_a?(Array) ? value.join(", ") : value.to_s
          end
        end

        def [](name)
          @entries[name.to_s.downcase]
        end

        def key?(name)
          @entries.key?(name.to_s.downcase)
        end

        def each(&block)
          @entries.each(&block)
        end

        def to_h
          @entries.dup
        end
      end
    end
  end
end
