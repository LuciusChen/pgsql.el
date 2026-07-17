# Changelog

Notable user-visible changes are recorded here.

## 0.1.0 - Unreleased

### Added

- Native protocol 3.0 connection startup with clear-text, MD5, and SCRAM-SHA-256 authentication.
- PostgreSQL-compatible SASLprep for non-ASCII SCRAM passwords, including raw-password fallback semantics.
- PostgreSQL SSL negotiation with explicit `disable`, `prefer`, `require`, and `verify-full` semantics.
- Atomic simple and extended query paths that consume responses through `ReadyForQuery` and expose server transaction state.
- `NotificationResponse` parsing through a public hook.
- Opaque connection and result values with ordinary public accessors, structured server diagnostics, notices, parameter status, distinct SQL NULL/false values, exact numeric and temporal semantics, core scalar/array/bytea codecs, and bounded separate-connection cancellation.
- Deterministic transcript tests, PostgreSQL 16 live coverage, package quality gates, and the protocol-library development contract.

### Fixed

- Empty `ParameterStatus` values no longer desynchronize startup or active sessions.
- Keyboard quit now cancels and drains the active request within a bounded recovery deadline before returning a synchronized connection, while failed recovery closes it safely.
- Connection and read timeouts accept fractional seconds, and callers can update both bounds through public setters.
- Binary result columns are rejected explicitly instead of being decoded as text.
