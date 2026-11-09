# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    class WebhooksTest < TestCase
      WEBHOOK_ID = "wh_01m24fj0js2r8nkr2pwhc6wykm"

      ENDPOINT = {
        "id" => WEBHOOK_ID,
        "channel_id" => "ch_01j6zk3m5x8qw2r7y9v4b1n0pd",
        "url" => "https://your-host.example/hooks/solarjuice",
        "events" => ["catalogue.updated", "specials.updated"],
        "status" => "active",
        "created_at" => "2026-09-11T05:12:40Z",
        "updated_at" => "2026-09-11T05:12:40Z",
        "consecutive_failures" => 0
      }.freeze

      CREATE_BODY = {
        "url" => "https://your-host.example/hooks/solarjuice",
        "events" => ["catalogue.updated", "specials.updated"],
        "description" => "Production catalogue sync"
      }.freeze

      def test_list_gets_the_webhooks_endpoint_and_returns_the_envelope
        client = build_client
        transport.enqueue(body: { "endpoints" => [ENDPOINT] })

        page = client.webhooks.list

        request = transport.last_request
        assert_equal :get, request.method
        assert_equal "https://api.solarjuice.com.au/v1/webhooks", request.url
        assert_equal [ENDPOINT], page["endpoints"]
      end

      def test_create_posts_json_and_returns_the_secret
        client = build_client
        created = ENDPOINT.merge("secret" => "whsec_0000000000000000")
        transport.enqueue(status: 201, body: created)

        endpoint = client.webhooks.create(CREATE_BODY)

        request = transport.last_request
        assert_equal :post, request.method
        assert_equal "https://api.solarjuice.com.au/v1/webhooks", request.url
        assert_equal "application/json", request.headers["Content-Type"]
        assert_equal CREATE_BODY, JSON.parse(request.body)
        assert_equal "whsec_0000000000000000", endpoint["secret"]
      end

      def test_delete_sends_delete_and_returns_an_empty_result_for_204
        client = build_client
        transport.enqueue(status: 204, body: nil)

        result = client.webhooks.delete(WEBHOOK_ID)

        request = transport.last_request
        assert_equal :delete, request.method
        assert_equal "https://api.solarjuice.com.au/v1/webhooks/#{WEBHOOK_ID}", request.url
        assert_nil request.body
        assert_equal 204, result.status_code
        assert_empty result
      end

      def test_enable_posts_to_the_enable_path_and_returns_the_endpoint
        client = build_client
        transport.enqueue(body: ENDPOINT)

        endpoint = client.webhooks.enable(WEBHOOK_ID)

        request = transport.last_request
        assert_equal :post, request.method
        assert_equal "https://api.solarjuice.com.au/v1/webhooks/#{WEBHOOK_ID}/enable", request.url
        assert_nil request.body
        assert_nil request.headers["Content-Type"]
        assert_equal "active", endpoint["status"]
      end

      def test_test_posts_to_the_test_path_and_returns_the_receipt
        client = build_client
        receipt = { "queued" => true, "event" => "webhook.test" }
        transport.enqueue(status: 202, body: receipt)

        result = client.webhooks.test(WEBHOOK_ID)

        request = transport.last_request
        assert_equal :post, request.method
        assert_equal "https://api.solarjuice.com.au/v1/webhooks/#{WEBHOOK_ID}/test", request.url
        assert_nil request.body
        assert_equal receipt, result
        assert_equal 202, result.status_code
      end

      def test_testing_a_disabled_endpoint_raises_validation_failed
        client = build_client(max_retries: 0)
        transport.enqueue_response(
          StubTransport.error_response(422, "VALIDATION_FAILED",
                                       message: "endpoint is disabled; POST /v1/webhooks/#{WEBHOOK_ID}/enable first")
        )

        error = assert_raises(ValidationFailedError) { client.webhooks.test(WEBHOOK_ID) }

        assert_equal 422, error.status_code
      end

      def test_another_channels_endpoint_raises_not_found
        client = build_client(max_retries: 0)
        transport.enqueue_response(StubTransport.error_response(404, "NOT_FOUND"))

        assert_raises(NotFoundError) { client.webhooks.enable(WEBHOOK_ID) }
      end

      def test_the_webhook_id_is_escaped
        client = build_client
        transport.enqueue(status: 204, body: nil)

        client.webhooks.delete("wh/one two")

        assert_equal "https://api.solarjuice.com.au/v1/webhooks/wh%2Fone%20two", transport.last_request.url
      end
    end
  end
end
