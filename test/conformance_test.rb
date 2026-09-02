# frozen_string_literal: true

require_relative "test_helper"

require "yaml"

module SolarJuice
  module PartnerApi
    # Reads spec/openapi.yaml and checks the gem against it, so that a new
    # operation added to the API fails the build here rather than being noticed
    # by a partner. YAML comes from the standard library, so this adds no
    # dependency of any kind.
    class ConformanceTest < TestCase
      SPEC_PATH = File.expand_path("../spec/openapi.yaml", __dir__)

      # operationId in the spec => how it is reached on a client. A nil resource
      # means the method sits on the client itself.
      IMPLEMENTATIONS = {
        "listCatalogue" => [:catalogue, :list],
        "getCatalogueProduct" => [:catalogue, :get],
        "listInventory" => [:inventory, :list],
        "getInventoryItem" => [:inventory, :get],
        "listSpecials" => [:specials, :list],
        "createShippingQuote" => [:shipping, :quote],
        "createOrder" => [:orders, :create],
        "listOrders" => [:orders, :list],
        "getOrder" => [:orders, :get],
        "cancelOrder" => [:orders, :cancel],
        "getHealth" => [nil, :health]
      }.freeze

      # Header parameters the SDK exposes as keyword arguments.
      HEADER_KEYWORDS = {
        "If-None-Match" => :if_none_match,
        "Idempotency-Key" => :idempotency_key
      }.freeze

      def self.spec
        @spec ||= YAML.safe_load(
          File.read(SPEC_PATH),
          permitted_classes: [Date, Time],
          aliases: true
        )
      end

      def spec
        self.class.spec
      end

      def operations
        spec["paths"].flat_map do |path, methods|
          methods.map { |verb, operation| [operation["operationId"], path, verb, operation] }
        end
      end

      def resolve(node)
        return node unless node.is_a?(Hash) && node.key?("$ref")

        node["$ref"].delete_prefix("#/").split("/").reduce(spec) { |doc, key| doc.fetch(key) }
      end

      def implementation_for(client, operation_id)
        resource_name, method_name = IMPLEMENTATIONS.fetch(operation_id)
        target = resource_name ? client.public_send(resource_name) : client
        [target, method_name]
      end

      def test_the_gem_version_matches_the_spec_version
        assert_equal spec.dig("info", "version"), VERSION,
                     "gem version and spec info.version must move together"
      end

      def test_the_default_base_url_is_the_documented_server
        assert_equal spec.dig("servers", 0, "url"), Client::DEFAULT_BASE_URL
      end

      def test_every_operation_in_the_spec_is_implemented
        client = build_client

        operations.each do |operation_id, path, verb, _operation|
          assert IMPLEMENTATIONS.key?(operation_id),
                 "#{verb.upcase} #{path} (#{operation_id}) has no SDK method"

          target, method_name = implementation_for(client, operation_id)
          assert_respond_to target, method_name, "#{operation_id} is mapped to a method that does not exist"
        end
      end

      def test_the_mapping_has_no_entries_the_spec_does_not_define
        spec_ids = operations.map(&:first)

        (IMPLEMENTATIONS.keys - spec_ids).each do |stale|
          flunk "#{stale} is mapped but no longer exists in the spec"
        end
      end

      def test_every_operation_hits_the_documented_path_and_verb
        client = build_client
        arguments = {
          "sku" => "GW-5000-DNS-30",
          "id" => "ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD"
        }

        operations.each do |operation_id, path, verb, operation|
          target, method_name = implementation_for(client, operation_id)
          transport.enqueue(status: 200, body: { "items" => [], "next_cursor" => nil })

          positional = []
          path_params = (operation["parameters"] || []).map { |p| resolve(p) }.select { |p| p["in"] == "path" }
          path_params.each { |parameter| positional << arguments.fetch(parameter["name"]) }
          # Only a required body is a positional argument. An optional one, as
          # on cancelOrder, is spelled as keyword options instead.
          positional << {} if operation.dig("requestBody", "required")

          target.public_send(method_name, *positional)

          request = transport.last_request
          expected = path.gsub(/\{(\w+)\}/) { arguments.fetch(Regexp.last_match(1)) }
          assert_equal expected, URI.parse(request.url).path, "#{operation_id} path"
          assert_equal verb.to_sym, request.method, "#{operation_id} verb"
        end
      end

      def test_every_query_and_header_parameter_is_an_option_on_the_method
        client = build_client

        operations.each do |operation_id, _path, _verb, operation|
          target, method_name = implementation_for(client, operation_id)
          keywords = target.method(method_name).parameters.select { |type, _| type == :key }.map(&:last)

          (operation["parameters"] || []).map { |p| resolve(p) }.each do |parameter|
            case parameter["in"]
            when "query"
              assert_includes keywords, parameter["name"].to_sym,
                              "#{operation_id} is missing the #{parameter['name']} option"
            when "header"
              expected = HEADER_KEYWORDS.fetch(parameter["name"])
              assert_includes keywords, expected,
                              "#{operation_id} is missing the #{parameter['name']} option"
            end
          end
        end
      end

      def test_every_list_operation_has_an_auto_pager
        client = build_client

        operations.each do |operation_id, _path, _verb, operation|
          parameters = (operation["parameters"] || []).map { |p| resolve(p) }
          next unless parameters.any? { |parameter| parameter["name"] == "cursor" }

          resource_name, = IMPLEMENTATIONS.fetch(operation_id)
          resource = client.public_send(resource_name)

          assert_respond_to resource, :auto_page, "#{operation_id} is paginated but has no auto_page"
          assert_kind_of Enumerator, resource.auto_page
        end
      end

      def test_every_error_code_in_the_spec_has_its_own_error_class
        codes = spec.dig("components", "schemas", "ErrorCode", "enum")

        assert_equal codes.sort, ERROR_CLASSES_BY_CODE.keys.sort
        codes.each do |code|
          klass = ERROR_CLASSES_BY_CODE.fetch(code)
          assert_operator klass, :<, ApiError, "#{code} maps to #{klass}, which is not an ApiError"
        end
      end

      def test_the_bearer_scheme_is_what_the_client_sends
        scheme = spec.dig("components", "securitySchemes", "bearerAuth")

        assert_equal "http", scheme["type"]
        assert_equal "bearer", scheme["scheme"]

        client = build_client
        transport.enqueue(body: {})
        client.health

        assert_match(/\ABearer /, transport.last_request.headers["Authorization"])
      end
    end
  end
end
