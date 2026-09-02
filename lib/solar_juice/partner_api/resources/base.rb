# frozen_string_literal: true

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
        def auto_page(**params)
          resource = self

          Enumerator.new do |yielder|
            cursor = params[:cursor]

            loop do
              page = resource.list(**params.merge(cursor: cursor))
              items = page["items"] || []
              items.each { |item| yielder << item }

              cursor = page["next_cursor"]
              # next_cursor is null on the last page. Guard on empty too, so a
              # future API that returns "" instead cannot loop forever.
              break if cursor.nil? || cursor.to_s.empty?
            end
          end
        end
      end
    end
  end
end
