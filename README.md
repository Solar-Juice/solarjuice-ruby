# Solar Juice Partner API for Ruby

Ruby client for the [Solar Juice Partner API](https://dev.solarjuice.com.au).

The Partner API lets an approved sales channel sell Solar Juice stock through
its own storefront: read your own price list and sellable inventory, see the
specials granted to you, get freight quotes that match the Solar Outlet checkout
exactly, and place orders against your trade account.

Zero runtime dependencies. Everything it needs (`net/http`, `json`, `uri`,
`time`, `securerandom`) ships with Ruby.

- API reference: <https://dev.solarjuice.com.au/docs>
- Developer program: <https://dev.solarjuice.com.au>
- The OpenAPI document this gem is built against: [`spec/openapi.yaml`](spec/openapi.yaml)

## Requirements

Ruby 3.0 or newer.

## Install

```ruby
# Gemfile
gem "solarjuice-partner-api", "~> 1.0"
```

or

```sh
gem install solarjuice-partner-api
```

## Quickstart

```ruby
require "solarjuice-partner-api"

client = SolarJuice::PartnerApi.new(api_key: ENV["SOLARJUICE_API_KEY"])

page = client.catalogue.list(limit: 50, brand: "GoodWe")
page["items"].each { |product| puts "#{product['sku']} #{product['price']}" }

quote = client.shipping.quote(
  destination: { suburb: "Parramatta", postcode: "2150", state: "NSW" },
  lines: [{ sku: "GW-5000-DNS-30", quantity: 1 }]
)
rate = quote["rates"].first
```

Responses are the decoded JSON body with string keys, exactly as documented in
the reference. Nothing is renamed or coerced, so a field added to the API is
readable without upgrading the gem.

## Authentication

Keys look like `sj_live_<keyid>_<secret>` or `sj_test_<keyid>_<secret>` and are
sent as `Authorization: Bearer <key>`. There is one host: a `sj_test_` key runs
against the same catalogue, prices and inventory, but orders placed with it are
flagged `sandbox: true` and never reach operations. Build with a test key, then
swap in a live key with no other change.

The key is read from `SOLARJUICE_API_KEY` when none is passed:

```ruby
client = SolarJuice::PartnerApi.new                       # from the environment
client = SolarJuice::PartnerApi.new(api_key: "sj_test_...") # explicit
```

With no key in either place, the constructor raises
`SolarJuice::PartnerApi::ConfigurationError`.

### Client options

| Option | Default | Meaning |
|---|---|---|
| `api_key:` | `ENV["SOLARJUICE_API_KEY"]` | Your partner key |
| `base_url:` | `https://api.solarjuice.com.au` | Override for a proxy or a test double |
| `timeout:` | `30` | Connect and read timeout in seconds |
| `max_retries:` | `3` | Retries after the first attempt |
| `user_agent:` | none | Suffix appended to `solarjuice-ruby/<version>` |
| `transport:` | `NetHttpTransport` | See [Testing](#testing) |

## Resources

| Group | Methods |
|---|---|
| `client.catalogue` | `list`, `auto_page`, `get(sku)` |
| `client.inventory` | `list`, `auto_page`, `get(sku)` |
| `client.specials` | `list`, `auto_page` |
| `client.shipping` | `quote(body)` |
| `client.orders` | `create(body, idempotency_key:)`, `list`, `auto_page`, `get(id, if_none_match:)` |
| `client` | `health` |

Option names match the API's parameter names, in snake case:
`client.orders.list(status: "accepted", updated_since: last_sync, limit: 200)`.

## Pagination

Every list endpoint is cursor paginated and returns the envelope
`{ "as_of", "items", "next_cursor" }` (catalogue adds `price_list_version`).
`list` gives you one page:

```ruby
page = client.inventory.list(limit: 200)
page["items"]
page["next_cursor"] # nil on the last page
```

`auto_page` gives you an `Enumerator` over the items of every page. It is lazy:
pages are fetched as they are needed, so taking the first 50 items costs one
request, not a whole catalogue walk.

```ruby
client.catalogue.auto_page(brand: "GoodWe").each do |product|
  upsert(product)
end

first_fifty = client.catalogue.auto_page.lazy.first(50)
```

### Incremental sync

`updated_since` takes the `as_of` from your previous response. The filter runs
off the API's own change sequence rather than record edit times, so nothing is
skipped because of clock differences.

```ruby
page = client.catalogue.list
watermark = page["as_of"]

# later
client.catalogue.auto_page(updated_since: watermark).each { |product| upsert(product) }
```

Inventory rows that have dropped to zero are still returned by an
`updated_since` query, with `total: 0`, so you can clear them locally.

## Placing an order

An order needs a `priced`, unexpired quote, the `price_list_version` the cart
was priced from, and `unit_price` values that match the current catalogue.

```ruby
receipt = client.orders.create(
  client_reference: "PO-88213",           # your reference, and the idempotency key
  price_list_version: client.price_list_version,
  quote_id: quote["quote_id"],
  rate_service_code: rate["service_code"],
  delivery: {
    name: "Jane Citizen", phone: "+61400000000",
    address1: "12 Example Street", suburb: "Parramatta",
    postcode: "2150", state: "NSW"
  },
  lines: [{ sku: "GW-5000-DNS-30", quantity: 1, unit_price: "1110.99" }]
)

receipt["id"]     # ord_01J6ZK3M5X8QW2R7Y9V4B1N0PD
receipt["status"] # received, because acceptance is asynchronous
```

## Idempotency

`client_reference` in the body is the only idempotency key. Resubmitting the
same reference with the same body returns the order that already exists (`200`
rather than the first call's `202`); a different body raises
`SolarJuice::PartnerApi::IdempotencyConflictError`. Sandbox and live keys have
separate reference namespaces.

`orders.create` also sends an `Idempotency-Key` header, yours if you pass
`idempotency_key:` and a generated UUID v4 otherwise, and puts it on the
result. The API accepts that header and ignores it: it is not stored, not
compared and not returned, so it is a local correlation value for your own
logs. After a create that timed out, find the order by your own reference
instead:

```ruby
page = client.orders.list(client_reference: "PO-88213")
```

Shipping quotes are cached rather than idempotent. A repeated quote for an
unchanged cart, destination and origin returns the same `quote_id` while it has
at least five minutes of validity left, and a new one after that. Read
`quote_id` and `expires_at` off the response you have rather than assuming
either behaviour.

## Polling an order

`orders.get` accepts an ETag. When nothing has changed the API answers `304`,
which this gem reports rather than raising:

```ruby
order = client.orders.get(order_id)
etag = order.etag

sleep 30
latest = client.orders.get(order_id, if_none_match: etag)
latest.not_modified? # true while the order is unchanged
```

A `304` still counts against your rate limit. To watch many orders at once, poll
`client.orders.auto_page(updated_since: watermark)` instead.

## Errors

Every error raised by this gem descends from `SolarJuice::PartnerApi::Error`,
and every error the API returns descends from `ApiError`, with one subclass per
documented error code.

```ruby
begin
  client.orders.create(body)
rescue SolarJuice::PartnerApi::PriceChangedError => e
  # details is a list of free-form objects whose keys depend on the code. For
  # PRICE_CHANGED it is the version pair followed by one entry per moved line:
  # [{ "price_list_version" => "plv_4c81ba09e7d2f6",
  #    "current_price_list_version" => "plv_9f3a2c1d84b6e05" },
  #  { "sku" => "GW-5000-DNS-30", "unit_price" => "1110.99",
  #    "current_price" => "1099.00" }]
  e.details
  refresh_catalogue_and_retry
rescue SolarJuice::PartnerApi::RateLimitedError => e
  sleep(e.retry_after || 60)
rescue SolarJuice::PartnerApi::ApiError => e
  logger.error("#{e.code} #{e.message} request_id=#{e.request_id}")
end
```

| Class | Code | HTTP |
|---|---|---|
| `UnauthorizedError` | `UNAUTHORIZED` | 401 |
| `ForbiddenError` | `FORBIDDEN` | 403 |
| `NotFoundError` | `NOT_FOUND` | 404 |
| `ValidationFailedError` | `VALIDATION_FAILED` | 422 |
| `RateLimitedError` | `RATE_LIMITED` | 429 |
| `PriceChangedError` | `PRICE_CHANGED` | 409 |
| `IdempotencyConflictError` | `IDEMPOTENCY_CONFLICT` | 409 |
| `QuoteUnavailableError` | `QUOTE_UNAVAILABLE` | 503 |
| `StaleDataError` | `STALE_DATA` | 503 |
| `InternalError` | `INTERNAL` | 500 |

Every one carries `code`, `message`, `details`, `request_id` and `status_code`.
Quote `request_id` when you raise a support request.

An unknown code, or an error body that is not the documented envelope, raises
`ApiError` itself with whatever could be read from the response. Network
failures and timeouts raise `TransportError` and `TimeoutError`, which carry no
status code because no response arrived.

## Retries

429, 502, 503, 504 and network failures are retried up to `max_retries` times
with exponential backoff starting at 500ms, doubling, with full jitter, capped
at 8 seconds. A `Retry-After` header wins over the computed delay. No other 4xx
is retried. Both `POST` endpoints are safe to retry: quotes have no side effect,
and orders are deduplicated by `client_reference`, which does not change
between attempts.

Set `max_retries: 0` to handle retries yourself.

## Rate limits

Limits are per key over a sliding one minute window, 600 requests per minute by
default. The last seen values sit on the client:

```ruby
client.rate_limit.limit      # 600
client.rate_limit.remaining  # 597
client.rate_limit.reset      # seconds until the window rolls over
client.last_request_id       # X-Request-Id of the last response
client.price_list_version    # X-Price-List-Version, set by catalogue reads
```

## Testing

The HTTP layer is injectable. A transport is anything that responds to
`#call(request)` and returns a `SolarJuice::PartnerApi::Transport::Response`, so
tests need no network and no stubbing library:

```ruby
class FakeTransport
  def call(request)
    SolarJuice::PartnerApi::Transport::Response.new(
      status: 200,
      headers: { "X-Request-Id" => "req_test" },
      body: JSON.generate({ "as_of" => "2026-09-02T04:10:11Z", "items" => [], "next_cursor" => nil })
    )
  end
end

client = SolarJuice::PartnerApi.new(api_key: "sj_test_key", transport: FakeTransport.new)
```

Raise `TransportError` from `#call` to exercise the retry path.

## Connections and threads

The default transport keeps one connection per host open and reuses it, so a
paging sync pays for one TLS handshake rather than one per page. Calls on a
single client are serialised on a mutex because a connection carries one request
at a time. For parallel work, build one client per thread. Call `client.close`
when you are finished with a client that will not be reused.

## Development

```sh
bundle install
bundle exec rake          # syntax check and tests
bundle exec rake test
```

The suite runs entirely against a stubbed transport. `test/conformance_test.rb`
parses `spec/openapi.yaml` and fails if the API grows an operation, a query
parameter or an error code this gem does not implement.

## Licence

MIT. See [LICENSE](LICENSE).
