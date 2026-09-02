# frozen_string_literal: true

require "securerandom"
require "uri"

module SolarJuice
  module PartnerApi
    # Small helpers shared by the client and the transport. Not part of the
    # public API; anything here may change without a major version bump.
    module Util
      # Anything outside the RFC 3986 unreserved set has to be percent encoded
      # in a path segment. A SKU is opaque and could hold a slash or a space, so
      # it is escaped rather than interpolated raw.
      PATH_UNSAFE = /[^A-Za-z0-9\-._~]/.freeze

      module_function

      # Builds a UUID v4 from secure random bytes rather than calling
      # SecureRandom.uuid, so the three SDKs generate keys the same way and the
      # version and variant bits are visible in one place.
      def uuid_v4
        bytes = SecureRandom.random_bytes(16).unpack("C*")
        bytes[6] = (bytes[6] & 0x0f) | 0x40 # version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80 # variant 10xx
        hex = bytes.map { |b| format("%02x", b) }.join
        [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
      end

      # Hand rolled rather than URI's escape, whose parsers and deprecations
      # have moved across the Ruby versions this gem supports.
      def escape_path_segment(value)
        value.to_s.b.gsub(PATH_UNSAFE) { |byte| format("%%%02X", byte.ord) }
             .force_encoding(Encoding::UTF_8)
      end

      # Drops nil values so an unset option never becomes "?brand=" and encodes
      # booleans as the strings the API documents.
      def encode_query(params)
        pairs = params.reject { |_, value| value.nil? }.map do |key, value|
          [key.to_s, value == true || value == false ? value.to_s : value.to_s]
        end
        return nil if pairs.empty?

        URI.encode_www_form(pairs)
      end
    end
  end
end
