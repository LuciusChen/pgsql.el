# Changelog

Notable user-visible changes are recorded here.

## Unreleased

### Added

- `pgsql-result-notices` returns the notices the server sent while producing a result, such as `RAISE NOTICE` output or `VACUUM VERBOSE` progress, as structured field plists, oldest first. Each request starts with none, so a caller no longer has to tell which request a notice from `pgsql-notice-functions` belongs to. Those functions still receive every notice.

## 0.3.0 - 2026-10-16

### Added

- `pgsql-copy-out-async` runs a `COPY ... TO STDOUT` statement without waiting and passes the copied rows, in order and from timers, to a function as they arrive, then calls the callback as `pgsql-exec-async` does. The function may wait for process output, as writing a remote file does: it is not called again until it returns, and the callback follows its last call. A function that signals stops the transfer: the command is cancelled and the callback receives that condition. `COPY FROM STDIN` remains unsupported.

### Changed

- Reading a backend message makes one string for its payload instead of three, which speeds up large results and COPY streams: streaming 181 MB through `pgsql-copy-out-async` into a file took 3.4 s in Emacs 30 with 32 MB of garbage collection headroom, and now takes 2.5 s.

## 0.2.0 - 2026-10-02

### Added

- `pgsql-exec-async` and `pgsql-exec-params-async` send a query without waiting. The process filter reads the response as it arrives and the callback runs once with the result or an error condition. The connection stays busy until the callback is scheduled, and `pgsql-cancel` ends the command with the server's verdict.

### Fixed

- MD5 and SCRAM-SHA-256 authentication with a non-ASCII password or user name failed whenever Emacs preferred a coding system other than UTF-8: the credentials were hashed in that coding system instead of as the UTF-8 bytes sent to the server.
- `pgsql-exec-params` could close the connection when the SQL or a parameter was a pure-ASCII multibyte string, such as text taken from a buffer: a type OID or parameter length with a byte of 0x80 or more (numeric, timestamptz, uuid, jsonb and array parameters, or a 200-byte text value) made the Parse or Bind length one byte too long, and PostgreSQL rejected it with `invalid message format`.
- A read timeout in `pgsql-exec` or `pgsql-exec-params` closed the connection without cancelling the statement, which kept running on the server and could commit after the caller saw the timeout. The timeout now cancels the statement and drains its response, as a keyboard quit does, and leaves the connection usable; if that recovery fails, the connection is closed as before.

## 0.1.0 - 2026-08-17

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
