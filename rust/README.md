# Convex from Rust

This educational Rust demonstration calls Convex over its documented JSON HTTP
endpoints and keeps one query updated through the pinned `/api/sync` WebSocket
profile. It is unofficial and is not a production SDK.

## Start here

The [canonical basic example](examples/basics/main.rs) creates a client, reads
a counter, starts Live, mutates the counter, and proves the Live update agrees.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and bearer-token replacement | Verified by shared local and hosted conformance |
| Live query snapshots, updates, unsubscribe, reconnect | Verified by shared local and hosted conformance |
| Live authentication and optimistic writes | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.rs -->
```rust
use convex_rust_demo::Client;
use serde_json::{Value, json};
use std::{env, time::Duration};

// Convex may encode a whole counter as either `1` or `1.0`. Accept both JSON
// spellings, but reject fractions so the example never hides a bad response.
fn whole_counter(value: &Value, operation: &str) -> i64 {
    if let Some(integer) = value.as_i64() {
        return integer;
    }
    let number = value
        .as_f64()
        .unwrap_or_else(|| panic!("{operation} count is not a number"));
    assert!(
        number.is_finite()
            && number.fract() == 0.0
            && number >= i64::MIN as f64
            && number <= i64::MAX as f64,
        "{operation} count is not a whole i64"
    );
    number as i64
}

fn main() {
    // Read the dedicated verification deployment and the unique counter room
    // supplied by the shared example runner.
    let url = env::var("CONVEX_URL").expect("CONVEX_URL is required");
    let room = env::args().nth(1).unwrap_or_else(|| "rust-example".into());

    // Create the native Rust client for the configured Convex deployment.
    let client = Client::new(&url).expect("create client");
    // Query the counter over Convex's documented HTTP endpoint.
    let current = client
        .query("demo:state", json!({"room": room}))
        .expect("current query");
    // Decode the JSON response into the integer this example compares below.
    let before = whole_counter(&current.value["count"], "query");
    println!("current count: {before}");

    // Start Live before mutating, so the initial snapshot and the later change
    // prove this is a real reactive subscription rather than HTTP polling.
    let live = client
        .subscribe("demo:state", json!({"room": room}))
        .expect("start Live");
    let initial = live
        .updates()
        .recv_timeout(Duration::from_secs(10))
        .expect("initial Live value");
    if let Some(error) = initial.error {
        panic!("initial Live error: {error}");
    }
    assert_eq!(
        whole_counter(
            &initial.value.expect("initial value")["count"],
            "initial Live"
        ),
        before
    );
    println!("live initial count: {before}");

    // Use a unique idempotency key so this mutation is safe if the example is retried.
    let mutation = client
        .mutation(
            "demo:increment",
            json!({
                "room": room,
                "language": "rust",
                "runId": uuid::Uuid::new_v4().to_string()
            }),
        )
        .expect("increment");
    assert_eq!(mutation.value["applied"], true);
    let after = whole_counter(&mutation.value["state"]["count"], "mutation");
    assert_eq!(after, before + 1);
    println!("mutation applied: true");
    println!("mutation count: {after}");

    // Read the resulting Live update and fail if it disagrees with the mutation.
    let updated = live
        .updates()
        .recv_timeout(Duration::from_secs(10))
        .expect("updated Live value");
    if let Some(error) = updated.error {
        panic!("updated Live error: {error}");
    }
    assert_eq!(
        whole_counter(
            &updated.value.expect("updated value")["count"],
            "updated Live"
        ),
        after
    );
    println!("live updated count: {after}");
    println!("verified count: {before} -> {after}");
    // Remove the Live query before closing the shared client and its owner loop.
    let _ = live.close();
    let _ = client.close();
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test rust` formats, tests, and compiles the binaries inside Docker.
`./run verify-example rust` executes the exact example. `./run verify rust`
runs the shared black-box adapter conformance profile.

## Protocol notes

The adapter speaks NDJSON v1 over stdin/stdout or the exact `ADAPTER_LISTEN`
TCP address. `debugDisconnect` is adapter-only and deliberately forces the
ordinary reconnect path. One owner thread serializes every Live query-set
change and acknowledges removal, disconnect, and close only after the state
transition completes. The adapter serializes subscription generations with its
NDJSON writer so stale relays cannot cross an acknowledgement.

Live delivery has a per-subscription newest-16 mailbox, dropping the oldest
intermediate value for a slow consumer. Reconnect backoff resets only after a
valid server message, and the client carries the newest observed timestamp into
the next `Connect` message.

## Limitations

This only implements the JSON-safe value subset. `TransitionChunk`, Live auth,
optimistic updates, and WebSocket mutations/actions are explicitly deferred.
