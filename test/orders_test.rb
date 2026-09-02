# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    class OrdersTest < TestCase
      ORDER_BODY = {
        "client_reference" => "PO-88213",
        "price_list_version" => "2026-09-02T04:00:00Z",
        "quote_id" => "qte_01J6ZK3M5X8QW2R7Y9V4B1N0PD",
        "rate_service_code" => "ALLIED-GENERAL",
        "delivery" => { "name" => "Jane Citizen", "postcode" => "2150" },
        "lines" => [{ "sku" => "GW-5000-DNS-30", "quantity" => 1, "unit_price" => "1110.99" }]
      }.freeze

      RECEIPT = { "id" => "ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD", "status" => "received" }.freeze

      def test_create_posts_json_to_the_orders_endpoint
        client = build_client
        transport.enqueue(status: 202, body: RECEIPT)

        receipt = client.orders.create(ORDER_BODY)

        request = transport.last_request
        assert_equal :post, request.method
        assert_equal "https://api.solarjuice.com.au/v1/orders", request.url
        assert_equal "application/json", request.headers["Content-Type"]
        assert_equal ORDER_BODY, JSON.parse(request.body)
        assert_equal RECEIPT, receipt
      end

      def test_create_generates_a_uuid_v4_idempotency_key_when_none_is_given
        client = build_client
        transport.enqueue(status: 202, body: RECEIPT)

        receipt = client.orders.create(ORDER_BODY)

        sent = transport.last_request.headers["Idempotency-Key"]
        assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, sent)
        assert_equal sent, receipt.idempotency_key
      end

      def test_generated_keys_differ_between_calls
        client = build_client
        2.times { transport.enqueue(status: 202, body: RECEIPT) }

        first = client.orders.create(ORDER_BODY).idempotency_key
        second = client.orders.create(ORDER_BODY).idempotency_key

        refute_equal first, second
      end

      def test_create_uses_the_callers_idempotency_key
        client = build_client
        transport.enqueue(status: 202, body: RECEIPT)

        receipt = client.orders.create(ORDER_BODY, idempotency_key: "3f2c9b7e-1c4a-4a2e-9a1f-0b7d5e6c8a90")

        assert_equal "3f2c9b7e-1c4a-4a2e-9a1f-0b7d5e6c8a90", transport.last_request.headers["Idempotency-Key"]
        assert_equal "3f2c9b7e-1c4a-4a2e-9a1f-0b7d5e6c8a90", receipt.idempotency_key
      end

      def test_a_reused_client_reference_with_a_different_body_raises
        client = build_client(max_retries: 0)
        transport.enqueue_response(
          StubTransport.error_response(409, "IDEMPOTENCY_CONFLICT", message: "already submitted")
        )

        error = assert_raises(IdempotencyConflictError) { client.orders.create(ORDER_BODY) }

        assert_equal 409, error.status_code
      end

      def test_price_changed_surfaces_the_current_values_in_details
        client = build_client(max_retries: 0)
        details = [
          { "field" => "lines[0].unit_price", "sku" => "GW-5000-DNS-30", "submitted" => "1110.99", "current" => "1099.00" }
        ]
        transport.enqueue_response(
          StubTransport.error_response(409, "PRICE_CHANGED", details: details)
        )

        error = assert_raises(PriceChangedError) { client.orders.create(ORDER_BODY) }

        assert_equal "1099.00", error.details.first["current"]
      end

      def test_get_returns_the_order_and_its_etag
        client = build_client
        transport.enqueue(body: RECEIPT, headers: { "ETag" => '"a1b2c3d4e5f6"' })

        order = client.orders.get("ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD")

        assert_equal "https://api.solarjuice.com.au/v1/orders/ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD", transport.last_request.url
        assert_equal '"a1b2c3d4e5f6"', order.etag
        refute order.not_modified?
        assert_nil transport.last_request.headers["If-None-Match"]
      end

      def test_get_sends_if_none_match_and_reports_304_without_raising
        client = build_client
        transport.enqueue(status: 304, headers: { "ETag" => '"a1b2c3d4e5f6"' }, body: nil)

        result = client.orders.get("ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD", if_none_match: '"a1b2c3d4e5f6"')

        assert_equal '"a1b2c3d4e5f6"', transport.last_request.headers["If-None-Match"]
        assert result.not_modified?
        assert_instance_of NotModified, result
        assert_equal '"a1b2c3d4e5f6"', result.etag
        assert_equal 304, result.status_code
        assert_empty result
      end

      def test_cancel_posts_to_the_cancel_path_and_returns_the_order
        client = build_client
        cancelled = { "id" => "ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD", "status" => "cancelled" }
        transport.enqueue(status: 200, body: cancelled)

        order = client.orders.cancel("ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD")

        request = transport.last_request
        assert_equal :post, request.method
        assert_equal "https://api.solarjuice.com.au/v1/orders/ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD/cancel", request.url
        assert_equal cancelled, order
        assert_equal "cancelled", order["status"]
      end

      def test_cancel_sends_no_body_when_there_is_no_note
        client = build_client
        transport.enqueue(status: 200, body: RECEIPT)

        client.orders.cancel("ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD")

        assert_nil transport.last_request.body, "the API records its own note when none is sent"
        assert_nil transport.last_request.headers["Content-Type"]
      end

      def test_cancel_sends_the_note_as_json
        client = build_client
        transport.enqueue(status: 200, body: RECEIPT)

        client.orders.cancel("ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD", note: "Customer changed the panel selection")

        request = transport.last_request
        assert_equal "application/json", request.headers["Content-Type"]
        assert_equal({ "note" => "Customer changed the panel selection" }, JSON.parse(request.body))
      end

      def test_cancel_escapes_the_order_id
        client = build_client
        transport.enqueue(status: 200, body: RECEIPT)

        client.orders.cancel("ord/one two")

        assert_equal "https://api.solarjuice.com.au/v1/orders/ord%2Fone%20two/cancel", transport.last_request.url
      end

      def test_cancelling_too_late_raises_validation_failed
        client = build_client(max_retries: 0)
        transport.enqueue_response(
          StubTransport.error_response(422, "VALIDATION_FAILED",
                                       message: "order is already processing and cannot be cancelled by the partner")
        )

        error = assert_raises(ValidationFailedError) do
          client.orders.cancel("ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD")
        end

        assert_equal 422, error.status_code
      end

      def test_list_passes_the_documented_filters
        client = build_client
        transport.enqueue(body: { "as_of" => "2026-09-02T04:21:02Z", "items" => [], "next_cursor" => nil })

        client.orders.list(status: "accepted", client_reference: "PO-88213", limit: 10)

        params = query_params(transport.last_request)
        assert_equal "accepted", params["status"]
        assert_equal "PO-88213", params["client_reference"]
        assert_equal "10", params["limit"]
      end

      def test_shipping_quote_posts_the_cart
        client = build_client
        quote = { "quote_id" => "qte_01J6ZK3M5X8QW2R7Y9V4B1N0PD", "quote_status" => "priced", "rates" => [] }
        transport.enqueue(body: quote)

        body = {
          destination: { suburb: "Parramatta", postcode: "2150", state: "NSW" },
          lines: [{ sku: "GW-5000-DNS-30", quantity: 1 }]
        }
        result = client.shipping.quote(body)

        request = transport.last_request
        assert_equal :post, request.method
        assert_equal "https://api.solarjuice.com.au/v1/shipping/quotes", request.url
        assert_equal "Parramatta", JSON.parse(request.body).dig("destination", "suburb")
        assert_equal quote, result
      end
    end
  end
end
