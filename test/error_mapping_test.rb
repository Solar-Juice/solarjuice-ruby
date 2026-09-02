# frozen_string_literal: true

require_relative "test_helper"

module SolarJuice
  module PartnerApi
    # The cross SDK response mapping table.
    #
    # test/fixtures/error-mapping.json is shared verbatim with the Node and PHP
    # clients: one response in, one decision out. The contract says the three
    # behave identically for the same inputs, and this is what makes a
    # divergence fail a test here rather than surface in a partner integration.
    # Add cases to sdks/error-mapping.json first, then copy it into all three.
    class ErrorMappingTest < TestCase
      TABLE = JSON.parse(File.read(File.expand_path("fixtures/error-mapping.json", __dir__))).freeze

      # The table's language neutral names, mapped onto this SDK's classes.
      CLASSES = {
        "Base" => ApiError,
        "Unauthorized" => UnauthorizedError,
        "Forbidden" => ForbiddenError,
        "NotFound" => NotFoundError,
        "ValidationFailed" => ValidationFailedError,
        "RateLimited" => RateLimitedError,
        "PriceChanged" => PriceChangedError,
        "IdempotencyConflict" => IdempotencyConflictError,
        "QuoteUnavailable" => QuoteUnavailableError,
        "StaleData" => StaleDataError,
        "Internal" => InternalError
      }.freeze

      NEXT_PAGE = { "as_of" => "2026-09-02T04:10:11Z", "items" => [], "next_cursor" => nil }.freeze

      def cases
        TABLE.fetch("cases")
      end

      # The row's headers stand alone rather than being merged into the stub's
      # usual set, so a row that says "no Retry-After" or "no request id" really
      # has none, exactly as the other two SDKs replay it.
      def response_for(row)
        Transport::Response.new(
          status: row.fetch("status"),
          headers: row.fetch("headers"),
          body: row.fetch("body")
        )
      end

      def test_every_case_maps_to_the_error_class_and_code_it_documents
        cases.each do |row|
          expected = row.fetch("expect")
          name = row.fetch("name")
          client = build_client(max_retries: 0)
          transport.enqueue_response(response_for(row))

          if expected.fetch("error").nil?
            refute_nil client.catalogue.list, "#{name} must not raise"
            next
          end

          error = assert_raises(Error, name) { client.catalogue.list }

          # Exact class, not just the ancestry: Base must not stand in for a
          # subclass, and a subclass must not stand in for Base.
          assert_instance_of CLASSES.fetch(expected.fetch("error")), error, name
          assert_code expected.fetch("code"), error.code, name
          assert_equal row.fetch("status"), error.status_code, name

          next unless expected.key?("retry_after_seconds")

          assert_code expected.fetch("retry_after_seconds"), error.retry_after, name
        end
      end

      def test_every_case_is_retried_exactly_when_the_table_says_so
        cases.each do |row|
          name = row.fetch("name")
          client = build_client(max_retries: 1)
          transport.enqueue_response(response_for(row))
          transport.enqueue(body: NEXT_PAGE)

          begin
            client.catalogue.list
          rescue Error
            # The class and code are asserted above; this pass only counts how
            # many times the request went out.
            nil
          end

          expected_calls = row.dig("expect", "retried") ? 2 : 1
          assert_equal expected_calls, transport.requests.size,
                       row.dig("expect", "retried") ? "#{name} should have been retried" : "#{name} must not be retried"
        end
      end

      def test_every_error_class_the_table_names_is_implemented_here
        named = cases.filter_map { |row| row.dig("expect", "error") }.uniq

        assert_empty named - CLASSES.keys
        assert_empty TABLE.fetch("error_classes").keys - CLASSES.keys - ["null"]
      end

      def test_the_table_covers_every_documented_error_code
        # A code added to the spec has to arrive with a row, or the three SDKs
        # can drift on it unnoticed.
        covered = cases.filter_map { |row| row.dig("expect", "code") }.uniq

        assert_empty ERROR_CLASSES_BY_CODE.keys - covered
      end

      def test_the_table_covers_every_status_the_client_retries
        retried = cases.select { |row| row.dig("expect", "retried") }.map { |row| row.fetch("status") }.uniq

        assert_empty Client::RETRYABLE_STATUSES - retried
      end

      private

      # Half the table's expectations are "no code" or "no Retry-After", and
      # minitest deprecates assert_equal with a nil expectation.
      def assert_code(expected, actual, message)
        expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
      end
    end
  end
end
