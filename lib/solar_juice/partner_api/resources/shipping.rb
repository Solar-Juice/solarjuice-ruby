# frozen_string_literal: true

require_relative "base"

module SolarJuice
  module PartnerApi
    module Resources
      # Freight quotes from the engine that prices the Solar Outlet checkout.
      class Shipping < Base
        # Quotes a cart to an Australian address. Check quote_status before
        # reading rates: only "priced" can be used on an order, and only until
        # expires_at.
        #
        #   quote = client.shipping.quote(
        #     destination: { suburb: "Parramatta", postcode: "2150", state: "NSW" },
        #     lines: [{ sku: "GW-5000-DNS-30", quantity: 1 }]
        #   )
        #
        # Quotes are not idempotent; every call returns a new quote_id.
        def quote(body)
          client.request(:post, "/v1/shipping/quotes", body: body, headers: json_content_type)
        end

        private

        def json_content_type
          { "Content-Type" => "application/json" }
        end
      end
    end
  end
end
