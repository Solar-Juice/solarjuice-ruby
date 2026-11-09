# frozen_string_literal: true

require_relative "base"
require_relative "../util"

module SolarJuice
  module PartnerApi
    module Resources
      # This channel's webhook endpoints. Any key for the channel can manage
      # them; the channel comes from the key, so only its own endpoints are
      # ever visible.
      class Webhooks < Base
        # Envelope: { "endpoints" }, every endpoint including disabled ones,
        # with delivery health. Not paginated, so there is no auto_page.
        def list
          client.request(:get, "/v1/webhooks")
        end

        # Registers an HTTPS URL and returns the endpoint with its signing
        # secret.
        #
        #   endpoint = client.webhooks.create(
        #     url: "https://your-host.example/hooks/solarjuice",
        #     events: ["catalogue.updated", "specials.updated"]
        #   )
        #   endpoint["secret"] # store it now: the API never returns it again
        def create(body)
          client.request(
            :post,
            "/v1/webhooks",
            body: body,
            headers: { "Content-Type" => "application/json" }
          )
        end

        # Deletes an endpoint and invalidates its secret. The API answers 204,
        # so the result is empty. An id from another channel is a 404, the same
        # as one that does not exist.
        def delete(id)
          client.request(:delete, "/v1/webhooks/#{Util.escape_path_segment(id)}")
        end

        # Switches a disabled endpoint back to active and returns it. The id and
        # the signing secret are kept, which is why this beats deleting and
        # registering again: nothing needs redeploying. Harmless on an endpoint
        # that is already active.
        def enable(id)
          client.request(:post, "/v1/webhooks/#{Util.escape_path_segment(id)}/enable")
        end

        # Queues one webhook.test delivery and returns the 202 receipt,
        # { "queued", "event", "note" }. It is signed and sent exactly like a
        # real event, so it proves the receiver and its signature check.
        #
        # A disabled endpoint raises ValidationFailedError rather than queueing
        # a delivery that would never be sent; enable it first.
        def test(id)
          client.request(:post, "/v1/webhooks/#{Util.escape_path_segment(id)}/test")
        end
      end
    end
  end
end
