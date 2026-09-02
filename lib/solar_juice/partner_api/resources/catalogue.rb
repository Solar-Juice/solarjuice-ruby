# frozen_string_literal: true

require_relative "base"
require_relative "../util"

module SolarJuice
  module PartnerApi
    module Resources
      # Products this channel can buy, priced for this channel.
      class Catalogue < Base
        include Paginated

        # Returns the decoded page envelope:
        # { "as_of", "price_list_version", "items", "next_cursor" }.
        #
        # updated_since takes the as_of from your previous sync; the API's own
        # change sequence drives it, so nothing is skipped by clock drift.
        def list(limit: nil, cursor: nil, updated_since: nil, brand: nil, category: nil)
          client.request(
            :get,
            "/v1/catalogue",
            query: {
              limit: limit,
              cursor: cursor,
              updated_since: updated_since,
              brand: brand,
              category: category
            }
          )
        end

        # One product. SKUs are case sensitive.
        def get(sku)
          client.request(:get, "/v1/catalogue/#{Util.escape_path_segment(sku)}")
        end
      end
    end
  end
end
