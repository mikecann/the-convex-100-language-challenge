# Go Convex client pilot

This directory contains a native Go implementation of Convex's documented HTTP
Functions API plus a deliberately small Live WebSocket client.

It does not wrap `convex-js`, `convex-rs`, the Convex CLI, `curl`, or another
runtime. `github.com/coder/websocket` supplies ordinary WebSocket transport;
all Convex-specific request, response, subscription, transition, reconnect,
and lifecycle behaviour is implemented here in Go.

## Protocol scope

HTTP uses the documented `/api/query`, `/api/mutation`, and `/api/action`
endpoints with `format: "json"`. It supports an optional user bearer token and
keeps success values, function logs, structured application error data, and
transport errors distinct.

The shared suite exercises absent, rejected, replaced, and cleared tokens. A
race-enabled Go transport test proves exact bearer-header forwarding. The pilot
does not claim a successful signed identity because the dedicated deployment
has no configured identity provider; that integration is outside the current
HTTP and Live scope.

Live is pinned to the internal `convex-rs` 0.10.4 profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It uses the unversioned
`/api/sync` endpoint and implements initial results, later transitions,
unsubscribe, reconnect with active-query restoration, query failures, server
inactivity detection, and deterministic close.

That source revision defines chunked transitions, but chunk assembly is
deliberately deferred from this pilot. Receiving `TransitionChunk` is surfaced
as protocol drift and causes a clean reconnect instead of silently corrupting
the subscription state.

This pin is a compatibility target, not a claim that Convex supports a stable
third-party sync protocol.

## Usage

```go
client, err := convex.New(
    os.Getenv("CONVEX_URL"),
    convex.WithBearerToken(os.Getenv("CONVEX_AUTH_TOKEN")),
)
if err != nil {
    return err
}
defer client.Close(context.Background())

result, err := client.Query(ctx, "demo:state", map[string]any{
    "room": "my-room",
})
if err != nil {
    return err
}

var state struct {
    Count int `json:"count"`
}
if err := json.Unmarshal(result.Value, &state); err != nil {
    return err
}

subscription, err := client.Subscribe(ctx, "demo:state", map[string]any{
    "room": "my-room",
})
if err != nil {
    return err
}
defer subscription.Close()

for update := range subscription.Updates() {
    if update.Err != nil {
        return update.Err
    }
    fmt.Println(string(update.Value))
}
```

The complete counter-room example is in `example/`.

## Adapter

The final image runs a thin Go adapter which accepts NDJSON protocol v1 on
stdin and reserves stdout for NDJSON events. It supports:

- `hello`
- `query`
- `mutation`
- `action`
- `subscribe`
- `unsubscribe`
- `close`

The adapter build also exposes `debugDisconnect`. This command is adapter-only
and test-only. It force-closes the current WebSocket while leaving the client
alive so the shared controller can test reconnect without Docker socket or host
network access. The hook is hidden from normal Go builds by the
`convexadapter` build tag.

Example handshake:

```json
{"protocolVersion":1,"id":"hello-1","op":"hello"}
```

Runtime variables:

- `CONVEX_URL`, required before the first network command.
- `CONVEX_AUTH_TOKEN`, optional bearer token for HTTP calls.

## Docker-only verification

No Go tooling should run on the host.

```sh
./run test go
./run verify go
./run verify-hosted go
```

`test` runs race-enabled unit tests against mock HTTP and WebSocket peers.
`verify` runs the complete JavaScript-oracle and Go black-box suites against the
pinned local backend. `verify-hosted` repeats them over current HTTPS and WSS.
Only those shared controller results can calculate HTTP or Live. Trusted-main
CI alone publishes the badges shown by the official evidence site.

## Outside the current HTTP and Live scope

- Full tagged Convex value encoding and Go-native Int64/bytes/special-float mappings.
- Live auth, auth rotation, and token refresh.
- WebSocket mutations and actions.
- Ordered mutation queue, mutation replay, and commit-timestamp resolution.
- Action non-replay guarantees.
- Query journals, reactive pagination, optimistic updates, and query deduplication.
- The npm-versioned sync profile and `TransitionChunk` assembly.
- Repeated fault, large-payload, and atomic multi-query-view testing.
