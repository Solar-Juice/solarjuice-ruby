# frozen_string_literal: true

require_relative "partner_api/version"
require_relative "partner_api/errors"
require_relative "partner_api/result"
require_relative "partner_api/transport"
require_relative "partner_api/net_http_transport"
require_relative "partner_api/util"
require_relative "partner_api/client"

module SolarJuice
  # Ruby client for the Solar Juice Partner API.
  #
  #   client = SolarJuice::PartnerApi.new(api_key: "sj_test_...")
  #   client.catalogue.auto_page.each { |product| puts product["sku"] }
  #
  # Reference: https://dev.solarjuice.com.au/docs
  module PartnerApi
    # Shorthand for Client.new, so the common case reads as one call.
    def self.new(**options)
      Client.new(**options)
    end
  end
end
