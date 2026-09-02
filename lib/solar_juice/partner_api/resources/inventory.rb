# frozen_string_literal: true

require_relative "base"
require_relative "../util"

module SolarJuice
  module PartnerApi
    module Resources
      # Sellable quantity per metro, the same figures the Solar Outlet
      # storefront sells from. Reading inventory does not reserve it.
      class Inventory < Base
        include Paginated

        # Envelope: { "as_of", "as_of_oldest", "stale", "locations", "items",
        # "next_cursor" }. With updated_since, SKUs that have dropped to zero
        # come back with total 0 so a local cache can clear them.
        def list(limit: nil, cursor: nil, updated_since: nil)
          client.request(
            :get,
            "/v1/inventory",
            query: { limit: limit, cursor: cursor, updated_since: updated_since }
          )
        end

        def get(sku)
          client.request(:get, "/v1/inventory/#{Util.escape_path_segment(sku)}")
        end
      end
    end
  end
end
