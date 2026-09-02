# frozen_string_literal: true

require_relative "../errors"

module SolarJuice
  module PartnerApi
    module Resources
      # Shared plumbing for the resource groups hanging off a client.
      class Base
        def initialize(client)
          @client = client
        end

        private

        attr_reader :client
      end

      # Adds auto_page to a resource that implements list.
      #
      # The Enumerator is lazy by construction: nothing is fetched until it is
      # iterated, and it fetches one page at a time, so
      #
      #   client.catalogue.auto_page.lazy.first(50)
      #
      # stops after the first page instead of walking the whole catalogue.
      module Paginated
        # Raised when the API hands back the cursor it was just given. Not one
        # of the spec's codes: it describes the SDK refusing to keep going, not
        # an error the API reported.
        PAGINATION_STALLED = "PAGINATION_STALLED"

        def auto_page(**params)
          resource = self

          Enumerator.new do |yielder|
            cursor = params[:cursor]

            loop do
              sent = cursor
              page = resource.list(**params.merge(cursor: cursor))
              items = page["items"] || []
              items.each { |item| yielder << item }

              cursor = page["next_cursor"]
              # next_cursor is null on the last page. Guard on empty too, so a
              # future API that returns "" instead cannot loop forever.
              break if cursor.nil? || cursor.to_s.empty?

              # A cursor that does not move would page forever and quietly burn
              # the partner's whole rate allowance, so fail loudly instead.
              next unless cursor == sent

              raise Error.new(
                "Pagination stopped making progress: the API returned the same cursor twice",
                code: PAGINATION_STALLED
              )
            end
          end
        end
      end
    end
  end
end
