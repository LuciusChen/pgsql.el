# pgsql.el Development Guide

Read this file before changing code, tests, or documentation. This repository contains a standalone PostgreSQL wire-protocol client for Emacs Lisp. Its instructions are self-contained; do not rely on another repository's agent guide at development time.

## Package Boundary

- `pgsql.el` owns PostgreSQL connection setup, authentication, wire framing, response parsing, type conversion, query execution, cancellation, and protocol state.
- It does not own a query console, result grid, completion, schema browser, connection prompts, saved connections, SQL rewriting, JDBC routing, or any other caller UI.
- Do not depend on Clutch or add caller-specific branches. Callers load `(require 'pgsql)` and use documented public `pgsql-` APIs.
- Do not call private APIs from another package. If a required capability is unavailable publicly, expose or implement it at the owning boundary.
- Keep the first usable release in one implementation file, `pgsql.el`. Split only when a stable responsibility can move whole and the split reduces total complexity. Do not create `wire`, `auth`, `codec`, `common`, or `utils` modules merely to shorten the main file.

## Initial Scope

The initial supported surface is intentionally focused:

- direct TCP and PostgreSQL SSL negotiation
- startup, clear-text, MD5, and SCRAM-SHA-256 authentication
- simple and extended query execution
- parameter binding, including a distinct SQL NULL value
- structured results, errors, notices, and server parameter updates
- core scalar and array codecs needed by real callers
- transaction state from `ReadyForQuery`
- query timeout and PostgreSQL cancellation

Connection pooling, pipelining, automatic SQL retry or replay, ORM behavior, migrations, replication, logical decoding, COPY streaming, and LISTEN/NOTIFY are out of scope until a concrete caller and tests justify them.

## Core Engineering

- Prefer the simplest model that is correct. Add abstractions only when they remove duplication, protect a real boundary, or simplify callers.
- Reduce code through clearer state, ownership, and control flow. Moving code or adding wrappers is not an architectural improvement by itself.
- Treat piles of tiny helpers, one-use wrappers, and pass-through accessors as design debt. Inline trivial helpers or fix the missing ownership boundary.
- Delete unused code rather than adding compatibility shims before the package has a released compatibility contract.
- Find the failing layer before changing behavior. Do not stack speculative fallbacks around a protocol or lifecycle bug.
- One failed fix should narrow the hypothesis. After two failed fixes on the same issue, stop patching and return to diagnosis.
- Keep experiments narrow. Do not expand the supported protocol surface until the smallest end-to-end slice works and is tested.

## PostgreSQL Wire Invariants

- A connection has at most one request in flight. Do not add implicit pipelining or concurrent reads.
- A process-filter chunk is not a message boundary. The parser must support arbitrary fragmentation and multiple coalesced messages.
- Validate message type, length, and payload boundaries before consuming a frame. Reject malformed or unreasonably large frames as protocol errors.
- A request completes only after its matching `ReadyForQuery` is consumed.
- After `ErrorResponse`, continue reading through `ReadyForQuery` before signaling the caller. If synchronization cannot be proven, mark the connection broken and close it.
- Keep process lifecycle, request/busy state, and server transaction state separate. `ReadyForQuery` values `I`, `T`, and `E` are the authority for transaction state.
- Never clear the receive buffer to conceal a parse failure or protocol misalignment.
- Never reset a connection to idle merely because a Lisp stack unwound. It is reusable only after protocol synchronization has been observed.
- Use `unwind-protect` only for real resource cleanup. It must not manufacture a successful request state after an incomplete exchange.
- Preserve structured fields from PostgreSQL errors and notices. Do not infer protocol meaning by matching human-readable error text.
- SQL NULL must have a dedicated representation distinct from Lisp `nil` and PostgreSQL boolean false in every parameter and result path.
- TLS `prefer` may downgrade only when the server explicitly rejects the PostgreSQL SSL request. Certificate, hostname, handshake, and transport errors must surface.
- Cancellation uses a separate connection and the server-issued backend key. The original connection must still consume its final response through `ReadyForQuery` before reuse.
- Do not automatically reconnect and replay SQL. The library cannot safely guess whether a statement or transaction may be repeated.

## Elisp and Public API Discipline

- Target Emacs 29.1 or newer. Do not raise the baseline silently.
- Every file starts with a lexical-binding file header and ends with its `provide` form and standard footer.
- Public symbols use `pgsql-`; private symbols use `pgsql--`. Public predicates with multi-word names end in `-p`.
- Treat connection and result objects as opaque public values. Keep internal constructors private and expose only documented accessors and operations.
- Prefer `let*`, `pcase-let`, plists, and small tables for short-lived data. Reserve structs for stable state crossing request or connection lifecycles.
- Require direct runtime dependencies explicitly. Do not rely on transitive loading or `eval-when-compile` for runtime dependencies.
- Loading `pgsql.el` must not open sockets, install editing hooks, or otherwise change active Emacs behavior.
- Use package-specific error conditions rooted at `pgsql-error`. Catch errors only at a boundary that can add real recovery or cleanup semantics; do not swallow internal failures and return plausible defaults.
- Keep control flow flat where practical, and separate pure framing/decoding from process I/O and state mutation.
- Protocol state machines may be longer when keeping the transition logic together makes invariants visible. Do not impose a mechanical function-line limit or create a helper ladder just to shorten them.
- All public functions, variables, customization options, and data accessors have accurate docstrings. Docstring argument names are uppercase.

## Testing

- Tests must fail when the implementation is wrong. Assert exact, distinguishable values rather than implementation trivia.
- Parser tests use exact unibyte protocol transcripts and cover fragmented, coalesced, truncated, malformed-length, and oversized frames.
- Cover startup and authentication state, simple and extended queries, prepared parameters, SQL NULL versus false, Unicode, arrays, core codecs, transaction states `I`/`T`/`E`, server-error recovery, broken connections, cancellation, reuse after cancellation, and TLS modes.
- Drive the public execution path for request-lifecycle bugs. A private parser test alone does not prove dispatch, synchronization, or reuse.
- Unit tests stay deterministic and do not require a server. Live tests live in `test/pgsql-live-test.el` and use the documented `PGSQL_TEST_*` environment variables.
- Use one PostgreSQL 16 live job initially. Do not add a database-version matrix before a real compatibility problem justifies it.
- For a real regression, establish a failing test before changing the implementation. Use the smallest test that proves the behavior.
- Treat tests as part of the architecture budget. Remove duplicate tests and tests that only freeze private helper structure.

## Documentation and Releases

- Keep `README.org` aligned with implemented behavior. Code is the source of truth when drift is found.
- Update `CHANGELOG.md` in the same change for public API, compatibility, behavior, or protocol-support changes. Pure test or internal cleanup need not add release noise.
- Keep the next version under an `Unreleased` heading until a release is intentionally cut and tagged.
- Keep one source paragraph on one line. Do not rewrap prose merely to fit a source-width limit; improve headings, paragraphs, and wording instead.
- Treat released artifacts as immutable. Changed release bytes require a new version and matching metadata.

## Pre-Commit Checklist

Read the full diff and then run:

```bash
git diff --check
./test/run-ci.sh all
```

For protocol execution, authentication, cancellation, TLS, or lifecycle changes, also run:

```bash
./test/run-ci.sh live
```

Before committing, verify that byte-compilation, checkdoc, and package-lint produce zero warnings and that no external private API leaked into the package:

```bash
rg -n -P "(?<![A-Za-z0-9-])(clutch|pg|mysql|mongodb|redis)--[A-Za-z0-9-]+" \
  pgsql.el test/*.el
```

The private-API scan must return no matches.
