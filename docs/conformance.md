# Conformance contract

Capability badges are awarded only by the shared black-box controller. A client manifest declares implementation intent and provenance, but it cannot award its own badges.

## Yellow: HTTP

The HTTP badge uses only Convex's documented public HTTP API:

- The client builds and runs in a clean Docker image.
- It exposes idiomatic query, mutation, and action APIs.
- It calls `/api/query`, `/api/mutation`, and `/api/action` directly.
- It sends documented `format: "json"` requests.
- It supports setting, replacing, and clearing `Authorization: Bearer <JWT>`.
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
- Automatic reconnect and restoration of active subscriptions.
- Reactive query failures remain typed subscription events, while transport
  interruptions exercise reconnect and do not masquerade as query failures.
- Clean client and subscription shutdown.

Realtime is not a documented stable third-party wire API. Every implementation must pin one protocol profile and record its source revision. It must not combine convenient pieces from incompatible official clients.

Known profile differences already include:

- Current Rust uses unversioned `/api/sync`.
- Convex JS 1.43.0 uses `/api/1.43.0/sync`.
- Both inspected schemas describe `TransitionChunk`, but Convex JS assembles it
  while the inspected convex-rs 0.10.4 base client treats it as unexpected.

Relevant sources:

- [Convex JS wire schema](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/sync/protocol.ts)
- [Convex JS sync endpoint](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/sync/client.ts#L325-L340)
- [Convex Rust sync types](https://github.com/get-convex/convex-rs/blob/6f1df8a8ba1665084ec001e307ca841ca17074d7/sync_types/README.md)
- [Convex Rust sync endpoint](https://github.com/get-convex/convex-rs/blob/6f1df8a8ba1665084ec001e307ca841ca17074d7/src/client/mod.rs#L420-L429)

## Experimental full values

The official JS HTTP client currently sends `format: "convex_encoded_json"` and tagged `$integer`, `$bytes`, and `$float` representations. That format is not listed as a supported public HTTP format, so it must not be silently folded into Yellow. Clients using it declare `experimentalFullValues: true` and pin the source revision they implement.

- [JS HTTP client source](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/browser/http_client.ts#L278-L339)
- [JS tagged value encoding](https://github.com/get-convex/convex-js/blob/8acd427d94ffb2ce9816283d791e74745fc89906/src/values/value.ts)

## Black-box tests

### HTTP suite

1. Query with nested JSON arguments and verify the result.
2. Mutate a counter and verify one database effect.
3. Run an action and verify its result.
4. Exercise absent, invalid, replaced, and cleared bearer tokens against the
   deployment. A language-local transport test must also prove that an opaque
   configured token is sent exactly as `Authorization: Bearer <token>`.
5. Preserve structured `ConvexError` data.
6. Keep function logs distinct from return values.
7. Pass null, booleans, finite Float64 values, UTF-8 strings, arrays, nested objects, and document IDs as strings.

Raw HTTP does not document client-side mutation queuing, so ordering is not required for Yellow.

Yellow proves bearer-token transport, not successful identity-provider
integration. A valid signed JWT and repeated auth rotation against an
auth-enabled fixture are outside the current HTTP and Live suites. This keeps
the experiment from claiming authentication semantics when its dedicated
deployment has no configured identity provider.

### Live suite

1. Subscribe and receive the initial result.
2. Observe a separate reference client's mutation without polling.
3. Unsubscribe and receive no later callback.
4. Drop the socket while idle, mutate state, reconnect, and observe current state.
5. Recover a reactive query after its underlying error is repaired.
6. Close without a reconnect, ghost callback, or hanging process.

## Adapter protocol

Every client image contains the library and a thin language-native adapter. The
same NDJSON stream works in two transports. With no `ADAPTER_LISTEN`, the
controller may use stdin and stdout. When `ADAPTER_LISTEN` is set, the adapter
listens on that TCP address, accepts one controller connection, and carries the
stream over that socket. The isolated Docker harness uses TCP so the controller
and client can remain separate containers without mounting the Docker socket.

The controller sends these commands:

- `hello`
- `query`
- `mutation`
- `action`
- `subscribe`
- `unsubscribe`
- `setAuth`
- `debugDisconnect` for a client attempting Live
- `close`

The adapter emits NDJSON responses containing request or subscription IDs. The
controller owns randomized fixtures, external reference mutations, assertions,
timeouts, fault injection, and capability calculation.

The first command is always `hello` and includes `protocolVersion: 1`. Its
`ready` response reports `protocolVersion`, the roster language ID,
implementation provenance, and runtime version. The adapter rejects unsupported
protocol versions. Every later command carries a request ID, and every
subscription event carries a subscription ID. Stdout is reserved for NDJSON
protocol events; human diagnostics go to stderr.

`debugDisconnect` is test-only fault injection. It closes the active WebSocket
without closing the client, allowing the controller to prove five real
reconnects and restored subscriptions. It must not appear in the educational
client API.

Every result records at least:

- Source commit and client tree hash.
- Final image and base image digests.
- Language and runtime version.
- Platform.
- Provenance label.
- Harness, vector, backend, and protocol profile revisions.
- Per-test status, duration, and evidence hash.
- Earned badges and failure reason.

The official JavaScript client is a semantic oracle for results, errors,
subscriptions, and lifecycle behaviour. It is not a byte-for-byte oracle for
Yellow HTTP because its current HTTP client uses the undocumented
`convex_encoded_json` format while Yellow deliberately uses the documented
`json` format.

Build success and platform verification are evidence fields, not capability
badges. Capability remains HTTP or Live.

The exact counter-room schema and indexes are frozen in
`docs/backend-contract.md`. Michael approved the dedicated schema and pilot
implementation on 5 August 2026. Any change to that schema requires fresh
approval before it is applied.
