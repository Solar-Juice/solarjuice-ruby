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
        #
        # state scopes the whole answer to one state: available is keyed by
        # the state and total is that state's stock rather than the national
        # figure. QLD is Brisbane plus Townsville. Case is ignored and the
        # spelt out name works, so "VIC", "vic" and "Victoria" are the same
        # request. NT, TAS and ACT have no warehouse and are refused with a
        # 400, as is any other value; nothing is silently ignored.
        def list(limit: nil, cursor: nil, updated_since: nil, state: nil)
          client.request(
            :get,
            "/v1/inventory",
            query: { limit: limit, cursor: cursor, updated_since: updated_since, state: state }
          )
        end

        def get(sku, state: nil)
          client.request(:get, "/v1/inventory/#{Util.escape_path_segment(sku)}", query: { state: state })
        end
      end
    end
  end
end
