# Changelog

All notable changes to this gem are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the gem follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0 - 2026-09-02

Initial release, matching version 1.0.0 of the Solar Juice Partner API.

### Added

- `SolarJuice::PartnerApi::Client` with the `catalogue`, `inventory`,
  `specials`, `shipping` and `orders` resource groups, plus `health`.
- `auto_page` on every list endpoint, returning a lazy `Enumerator` that walks
  `next_cursor` and yields each item.
- Automatic `Idempotency-Key` on `orders.create`, generated as a UUID v4 when
  the caller does not supply one and returned on the result.
- Conditional reads: `orders.get(id, if_none_match:)` answers a `304` with a
  `NotModified` result instead of raising.
- Retries with exponential backoff and full jitter on 429, 502, 503, 504 and
  network failures, honouring `Retry-After`.
- An error class per documented error code, all under
  `SolarJuice::PartnerApi::Error`.
- Rate limit headers, the last request id and the price list version exposed on
  the client after every call.
- An injectable transport for testing without a network.
