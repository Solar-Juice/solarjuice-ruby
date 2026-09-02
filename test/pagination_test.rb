# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    class PaginationTest < TestCase
      def page(items, next_cursor)
        { "as_of" => "2026-09-02T04:10:11Z", "items" => items, "next_cursor" => next_cursor }
      end

      def test_auto_page_walks_every_page_and_yields_elements
        client = build_client
        transport.enqueue(body: page([{ "sku" => "A" }, { "sku" => "B" }], "cursor-2"))
        transport.enqueue(body: page([{ "sku" => "C" }], nil))

        skus = client.catalogue.auto_page.map { |product| product["sku"] }

        assert_equal %w[A B C], skus
        assert_equal 2, transport.requests.size
        assert_equal "cursor-2", query_params(transport.requests.last)["cursor"]
      end

      def test_auto_page_returns_an_enumerator_that_fetches_nothing_until_iterated
        client = build_client
        enumerator = client.inventory.auto_page

        assert_kind_of Enumerator, enumerator
        assert_empty transport.requests
      end

      def test_auto_page_is_lazy_enough_to_stop_after_the_first_page
        client = build_client
        transport.enqueue(body: page([{ "sku" => "A" }, { "sku" => "B" }], "cursor-2"))
        # Only one page is queued on purpose: asking for two items must not
        # reach for a second page, and the stub raises if it does.

        assert_equal %w[A B], client.catalogue.auto_page.lazy.first(2).map { |item| item["sku"] }
        assert_equal 1, transport.requests.size
      end

      def test_auto_page_carries_the_filters_onto_every_page
        client = build_client
        transport.enqueue(body: page([{ "sku" => "A" }], "cursor-2"))
        transport.enqueue(body: page([{ "sku" => "B" }], nil))

        client.catalogue.auto_page(brand: "GoodWe", limit: 1).to_a

        transport.requests.each do |request|
          params = query_params(request)
          assert_equal "GoodWe", params["brand"]
          assert_equal "1", params["limit"]
        end
      end

      def test_auto_page_starts_from_a_supplied_cursor
        client = build_client
        transport.enqueue(body: page([{ "sku" => "C" }], nil))

        client.orders.auto_page(cursor: "resume-here").to_a

        assert_equal "resume-here", query_params(transport.requests.first)["cursor"]
      end

      def test_auto_page_stops_on_a_null_cursor_and_on_an_empty_page
        client = build_client
        transport.enqueue(body: page([], nil))

        assert_empty client.specials.auto_page.to_a
        assert_equal 1, transport.requests.size
      end

      def test_auto_page_treats_an_empty_string_cursor_as_the_end
        client = build_client
        transport.enqueue(body: page([{ "sku" => "A" }], ""))

        assert_equal 1, client.inventory.auto_page.to_a.size
        assert_equal 1, transport.requests.size
      end

      def test_every_list_resource_has_an_auto_page
        client = build_client

        %i[catalogue inventory specials orders].each do |group|
          resource = client.public_send(group)
          assert_respond_to resource, :list
          assert_respond_to resource, :auto_page
        end
      end

      def test_auto_page_rejects_a_filter_the_endpoint_does_not_have
        client = build_client

        assert_raises(ArgumentError) { client.inventory.auto_page(brand: "GoodWe").to_a }
      end
    end
  end
end
