# Changelog

Notable user-visible changes are recorded here.

## 0.1.0 - Unreleased

### Added

- Native protocol 3.0 connection startup with clear-text, MD5, and SCRAM-SHA-256 authentication.
- PostgreSQL SSL negotiation with explicit `disable`, `prefer`, `require`, and `verify-full` semantics.
- Atomic simple and extended query paths that consume responses through `ReadyForQuery` and expose server transaction state.
- Opaque connection state, structured results, server diagnostics, notices, parameter status, distinct SQL NULL/false values, exact numeric and temporal semantics, core scalar/array/bytea codecs, and bounded separate-connection cancellation.
- Deterministic transcript tests, PostgreSQL 16 live coverage, package quality gates, and the protocol-library development contract.
