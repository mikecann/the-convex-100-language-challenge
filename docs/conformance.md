# Conformance contract

Capability badges are awarded only by the shared black-box controller. A client manifest declares implementation intent and provenance, but it cannot award its own badges.

## Yellow: HTTP

The HTTP badge uses only Convex's documented public HTTP API:

- The client builds and runs in a clean Docker image.
- It exposes idiomatic query, mutation, and action APIs.
- It calls `/api/query`, `/api/mutation`, and `/api/action` directly.
- It sends documented `format: "json"` requests.
- It supports `Authorization: Bearer <JWT>`.
- It preserves successful values, `errorMessage`, application `errorData`, and `logLines`.
- It passes the JSON-safe value suite.

The public JSON format is deliberately a smaller contract. It cannot represent every Convex value without ambiguity. Int64, bytes, special floats, and ordinary strings can overlap in their exported JSON representations. Yellow therefore does not claim lossless Int64, bytes, NaN, infinities, or negative zero.

Relevant sources:

- [Convex HTTP API](https://docs.convex.dev/http-api/)
- [Convex data types](https://docs.convex.dev/database/types)
- [OpenAPI and other languages](https://docs.convex.dev/client/open-api)

## Green: Live

The Live badge includes Yellow and additionally requires:

- A WebSocket subscription, not polling.
- Initial and subsequent query values.
- Unsubscribe.
- Auth changes on the live connection.
- Automatic reconnect and restoration of active subscriptions.
- Distinct query, mutation, action, auth, and transport failures.

Realtime is not a documented stable third-party wire API. Every implementation must pin one protocol profile and record its source revision. It must not combine convenient pieces from incompatible official clients.

Known profile differences already include:

- Current Rust uses unversioned `/api/sync`.
- Convex JS 1.43.0 uses `/api/1.43.0/sync`.
- The JS profile supports `TransitionChunk`; the inspected Rust profile does not.

Relevant sources:

- [Convex JS wire schema](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/sync/protocol.ts)
- [Convex JS sync endpoint](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/sync/client.ts#L325-L340)
- [Convex Rust sync types](https://github.com/get-convex/convex-rs/blob/6f1df8a8ba1665084ec001e307ca841ca17074d7/sync_types/README.md)
- [Convex Rust sync endpoint](https://github.com/get-convex/convex-rs/blob/6f1df8a8ba1665084ec001e307ca841ca17074d7/src/client/mod.rs#L420-L429)

## Blue: Hardened realtime

The Hardened badge includes Live and additionally requires:

- Complete Convex value encoding for the pinned profile.
- Atomic application of every transition so subscriptions represent one logical timestamp.
- Ordered mutations.
- Reconnection of an interrupted mutation using the same session and request identity, with one database effect.
- No automatic retry of an uncertain in-flight action.
- Mutation success held until subscribed state advances through its commit timestamp.
- Query journals and large transitions where the selected profile includes them.
- Repeated auth rotation, disconnect, and lifecycle tests.

The official request manager demonstrates the important distinction between reconnecting mutations and not replaying actions: [request manager source](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/sync/request_manager.ts#L137-L225).

## Experimental full values

The official JS HTTP client currently sends `format: "convex_encoded_json"` and tagged `$integer`, `$bytes`, and `$float` representations. That format is not listed as a supported public HTTP format, so it must not be silently folded into Yellow. Clients using it declare `experimentalFullValues: true` and pin the source revision they implement.

- [JS HTTP client source](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/http_client.ts#L278-L339)
- [JS tagged value encoding](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/values/value.ts)

## Black-box tests

### HTTP suite

1. Query with nested JSON arguments and verify the result.
2. Mutate a counter and verify one database effect.
3. Run an action and verify its result.
4. Exercise valid, absent, invalid, replaced, and cleared bearer tokens.
5. Preserve structured `ConvexError` data.
6. Keep function logs distinct from return values.
7. Pass null, booleans, finite Float64 values, UTF-8 strings, arrays, nested objects, and document IDs as strings.

Raw HTTP does not document client-side mutation queuing, so ordering is not required for Yellow.

### Live suite

1. Subscribe and receive the initial result.
2. Observe a separate reference client's mutation without polling.
3. Unsubscribe and receive no later callback.
4. Drop the socket while idle, mutate state, reconnect, and observe current state.
5. Rotate from user A to user B and re-evaluate protected subscriptions.
6. Recover a reactive query after its underlying error is repaired.

### Hardened suite

1. Maintain an invariant across two subscriptions while a transaction repeatedly changes both values.
2. After awaiting a mutation, expose subscribed state that already includes the write.
3. Preserve server-observed order for mutations A, B, and C fired without awaiting between calls.
4. Disconnect after the server receives a mutation but before its response, then settle once with one database effect.
5. Disconnect an in-flight action and do not replay it.
6. Round-trip Int64 boundaries, bytes, special floats, negative zero, Unicode, and nested values.
7. Never regress to an older observed state after reconnect.
8. Survive rapid subscribe, unsubscribe, and resubscribe churn.
9. Recover protected subscriptions after replacing expired or invalid auth.
10. Close cleanly without ghost callbacks or a hanging container.
11. Exercise profile-specific query journals and large-transition chunks.
12. Pass every fault case 20 consecutive times.

## Adapter protocol

Every client image contains the library and a thin language-native adapter. The controller sends newline-delimited JSON commands over stdin:

- `hello`
- `query`
- `mutation`
- `action`
- `subscribe`
- `unsubscribe`
- `setAuth`
- `close`

The adapter emits timestamped NDJSON responses containing request or subscription IDs. The controller owns fixture reset, randomized nonces, external reference mutations, the fault proxy, assertions, timeouts, and badge calculation.

Every result records at least:

- Source commit and client tree hash.
- Final image and base image digests.
- Language and runtime version.
- Platform.
- Provenance label.
- Harness, vector, backend, and protocol profile revisions.
- Per-test status, duration, and evidence hash.
- Earned badges and failure reason.

The proposed Convex test schema and auth fixture remain approval-gated. No schema may be created or applied until Michael approves the exact fields and indexes.
