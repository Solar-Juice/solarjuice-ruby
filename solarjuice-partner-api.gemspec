# frozen_string_literal: true

require_relative "lib/solar_juice/partner_api/version"

Gem::Specification.new do |spec|
  spec.name = "solarjuice-partner-api"
  spec.version = SolarJuice::PartnerApi::VERSION
  spec.authors = ["Solar Juice"]
  spec.email = ["developers@solarjuice.com.au"]

  spec.summary = "Ruby client for the Solar Juice Partner API."
  spec.description = "Catalogue, pricing, inventory, specials, shipping quotes and orders " \
                     "for approved Solar Juice sales channels. No runtime dependencies."
  spec.homepage = "https://dev.solarjuice.com.au"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "documentation_uri" => "https://dev.solarjuice.com.au/docs",
    "source_code_uri" => "https://github.com/Solar-Juice/solarjuice-ruby",
    "changelog_uri" => "https://github.com/Solar-Juice/solarjuice-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/Solar-Juice/solarjuice-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  # Globbed rather than taken from git, so the gem builds the same way in a
  # release pipeline that only has the source tree.
  spec.files = Dir[
    "lib/**/*.rb",
    "spec/openapi.yaml",
    "README.md",
    "CHANGELOG.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  # No runtime dependencies by design: net/http, json, uri, time and
  # securerandom all ship with Ruby.
end
