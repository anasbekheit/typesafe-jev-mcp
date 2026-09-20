# Design

`typesafe-jev-mcp` is an MCP stdio server exposing one tool, `evaluate`, which forwards typed
questions to TypeSafe's Jev model. It surfaces to clients as `mcp__jev__evaluate`.

There are no comments in the source and no tests. This file is where the reasoning lives.

## Measured API truth

Probed against `https://api.typesafe.ai/v1/systemone` on 2026-09-20. Where this table
and TypeSafe's published docs disagree, the table is what the API actually did.

| Input | Result |
|---|---|
| unknown question type (15 names tried) | `400` `{"detail":{"error_type":"api_usage_error","message":"Invalid request."}}` |
| unknown top-level request field | `400`, same opaque body — the request schema is closed |
| score with 1 level | **`200`** — docs claim a 2-level minimum; they are wrong |
| score with 11 levels | `400` `{"detail":"Too many score levels. Must have at most 10 levels."}` |
| choice with 256 options | `400` `{"detail":"Too many choices. Must have at most 255 choices."}` |
| two choice questions, 200 options each | `200` — the 255 cap is **per question**, not global |
| 60 questions in one call | `200` — no separate question cap |
| choice criteria with `null` descriptions | `200` |
| `state` as an object, integer > 2^53 | `200` |
| oversize state (810 KB) | `400` `{"detail":{"error_type":"max_tokens_exceeded"}}` — **no `message` field** |
| invalid key | `401` `{"detail":{"error_type":"authentication_error","message":"..."}}` |
| `model` omitted | `422`, Pydantic array: `[{"type":"missing","loc":["body","model"],...}]` |
| empty `questions` | `422`, Pydantic array |
| unknown model | `400` `{"detail":{"error_type":"api_usage_error","message":"Unknown model: jev-9.9.9"}}` |
| `jev-preview` | `200`, resolved to `jev-1.13.0` |
| 210 concurrent requests | all `200`; no rate limit reached, no `Retry-After` or `RateLimit-*` headers observed |

Two corrections to the published docs: the score minimum is **1**, not 2; and validation
failures are **400** for semantic problems, **422** only for Pydantic shape problems.

`detail` is polymorphic across four shapes: a string, an object with `message`, an object
with **only** `error_type`, and an array of Pydantic problems. `describe` in `jev.rs`
handles all four and falls back to the raw body.

## Decisions

**The question enum is closed.** Fifteen plausible undocumented type names were rejected,
and the API rejects unknown top-level fields the same way, so it reads as a closed
discriminated union over exactly three types. Forwarding an unknown type would trade a
clear local error for the API's opaque `"Invalid request."`. Serde's own message —
``unknown variant `rank`, expected one of `noul`, `choice`, `score` `` — is better than
anything worth hand-writing, and costs nothing. If TypeSafe ship a fourth type, adding a
variant is a release, which it would need anyway for validation and schema.

**Answers are a typed enum, not raw JSON.** `noul` carries no `confidence`; only `choice`
and `score` do. Making that an enum encodes it structurally rather than as an `Option`
that is always `None` for one variant. `legend` and `probabilities` come back as
index-keyed objects even though `criteria` goes in as an array.

The cost: a field TypeSafe adds is dropped until this crate is updated. Accepted, because
`Json<T>` is what generates the `outputSchema` clients branch on, and exposing a new field
would need a release regardless.

**`serde_json::Value`, not `RawValue`.** `RawValue` cannot deserialize from an
already-parsed `Value`, which is what rmcp hands to a tool. It is not an option here.
This costs nothing: `serde_json::Number` stores integers as i64/u64, so values past 2^53
survive exactly — verified with `9007199254740993` and `12345678901234567890`. The
float64 rounding that the Go implementation works around does not arise in Rust.

**`preserve_order` is on.** Without it `serde_json::Map` is a `BTreeMap` and a caller's
choice options would be silently alphabetized before the model sees them. The API returns
`probabilities` in arbitrary order, which hints it may not care, but silently reordering a
caller's input is not a behavior to introduce on a hint.

**Limits are validated locally** only where measured: choice 1..=255 per question, score
1..=10, questions non-empty. Error paths name the question as `questions["id"]` with the
id quoted, so an id containing a dot cannot read as nesting the request never had.

**`max_tokens_exceeded` is rewritten client-side.** The API returns that error type with no
message at all. The tool substitutes the actual ceilings (64k combined, 32k state) and
what to do about it. No local token counting: that needs a tokenizer to approximate a
limit the server already enforces exactly.

**One deadline covers the whole retry sequence.** 60 seconds via `tokio::time::timeout`
around the loop, not per attempt. Per-attempt timeouts with a retry loop is how the Go
implementation reaches a worst case near 247 seconds.

**Retries cover 429, 529, connect errors and timeouts.** The last two are the gap in the
Go implementation, which returns immediately on any transport error, so a transient reset
fails the whole tool call.

**No jitter on the backoff.** Questions batch into a single request by design, so one tool
call is one request, and lockstep retries across concurrent calls from one agent are rare
enough not to pay for. Revisit if that stops being true.

**The response is read fully, then rejected if over 1 MiB.** It is never truncated, so the
failure mode the Go implementation hit — an overlong body cut mid-JSON and returned as a
successful answer — cannot occur. With input capped at 64k tokens, 1 MiB is unreachable in
normal use.

**No tracing subscriber.** stdout carries the MCP protocol, and the usual way to corrupt
it is `tracing_subscriber::fmt()`, which defaults to stdout. Installing none removes the
failure rather than configuring around it. Startup errors go to stderr via `eprintln`.

**The key never lands in a struct that derives `Debug`.** `Secret` has a hand-written
`Debug` printing `[redacted]`, and the `Authorization` header value is marked sensitive so
`HeaderValue`'s own `Debug` prints `Sensitive`.

**TLS is rustls with bundled roots, which pulls a C dependency.** `rustls` selects the
`aws-lc-rs` provider, and `aws-lc-sys` under it is C and assembly. Native builds on Linux,
macOS and Windows are fine, but cross-compiling needs that platform's C toolchain, so release
builds must run on a native runner per target rather than cross-compiling. The alternative,
`native-tls`, would reintroduce OpenSSL on Linux, which is the thing bundled roots avoid.

**The exec helper picks its shell at compile time.** `sh -c` on Unix, `cmd /C` on Windows,
through `cfg!(windows)` rather than duplicated `#[cfg]` functions: both arms type-check
everywhere and the dead one is eliminated. Running the command through a shell is the point
of the pattern, since it lets a key come from a pipeline.

**TypeSafe only, no OpenRouter.** One endpoint, one default model, one key lookup.
OpenRouter's Decisions endpoint is on an `/api/alpha/` path its own docs warn may move.

**No setup or self-update subcommands.** Distribution belongs to package managers. A
self-updater is a permanent security surface, and the Go implementation's could not even
survive its own rename.

## Not done

- No `LICENSE` file yet, though `Cargo.toml` declares MIT.
- No CI.
- `Retry-After` is honored if present but has never been observed; 210 concurrent requests
  did not reach a rate limit.
- schemars emits `"format": "uint64"` for the `usage` counts. JSON Schema treats an
  unrecognized `format` as an annotation validators must ignore, and the MCP Inspector
  prints a note about it. Silencing it needs a hand-written schema for a cosmetic warning,
  which is not worth the code.
