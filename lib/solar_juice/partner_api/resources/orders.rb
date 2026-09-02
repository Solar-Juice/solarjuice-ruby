# frozen_string_literal: true

require_relative "base"
require_relative "../util"

module SolarJuice
  module PartnerApi
    module Resources
      # Orders placed against this channel's trade account.
      class Orders < Base
        include Paginated

        # Places an order and returns the 202 receipt, which starts in status
        # "received" because acceptance is asynchronous.
        #
        # An Idempotency-Key header is always sent: the caller's value when
        # given, otherwise a fresh UUID v4. The key used is on the result as
        # result.idempotency_key so it can be logged next to the order.
        #
        # Note that client_reference in the body is what actually makes the call
        # idempotent on the API side. The header is recorded for reconciliation.
        def create(body, idempotency_key: nil)
          key = idempotency_key || Util.uuid_v4

          result = client.request(
            :post,
            "/v1/orders",
            body: body,
            headers: {
              "Content-Type" => "application/json",
              "Idempotency-Key" => key
            }
          )
          result.idempotency_key = key
          result
        end

        # Envelope: { "as_of", "items", "next_cursor" }, newest first. Poll with
        # updated_since to pick up status changes across every order in one
        # request rather than polling each order.
        def list(limit: nil, cursor: nil, updated_since: nil, status: nil, client_reference: nil)
          client.request(
            :get,
            "/v1/orders",
            query: {
              limit: limit,
              cursor: cursor,
              updated_since: updated_since,
              status: status,
              client_reference: client_reference
            }
          )
        end

        # One order with its full event history.
        #
        # Pass the ETag from a previous read as if_none_match and an unchanged
        # order comes back as a NotModified: an empty result whose
        # not_modified? is true, carrying the ETag. It is not an error.
        #
        #   order = client.orders.get(id)
        #   later = client.orders.get(id, if_none_match: order.etag)
        #   later.not_modified? # => true while nothing has changed
        def get(id, if_none_match: nil)
          headers = if_none_match ? { "If-None-Match" => if_none_match } : {}
          client.request(:get, "/v1/orders/#{Util.escape_path_segment(id)}", headers: headers)
        end
      end
    end
  end
end
