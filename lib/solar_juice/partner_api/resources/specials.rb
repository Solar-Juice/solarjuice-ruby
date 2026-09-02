# frozen_string_literal: true

require_relative "base"

module SolarJuice
  module PartnerApi
    module Resources
      # Time boxed prices granted to this channel. They are already folded into
      # the catalogue price, so this group is for display and for knowing when a
      # price is about to change.
      class Specials < Base
        include Paginated

        # Envelope: { "as_of", "items", "next_cursor" }.
        def list(limit: nil, cursor: nil, updated_since: nil, active: nil, sku: nil)
          client.request(
            :get,
            "/v1/specials",
            query: {
              limit: limit,
              cursor: cursor,
              updated_since: updated_since,
              active: active,
              sku: sku
            }
          )
        end
      end
    end
  end
end
