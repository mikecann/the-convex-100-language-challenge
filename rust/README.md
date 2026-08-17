<img src="logo.png" alt="Rust logo" width="96">
<!-- Logo source: https://www.rust-lang.org/static/images/rust-logo-blk.svg -->

# Rust

[Rust](https://www.rust-lang.org/) is a compiled systems language built for
reliable, efficient software. Its ownership model provides memory and thread
safety without a garbage collector, giving it C- and C++-like control with more
checks at compile time. [Rust 1.0 arrived in
2015](https://blog.rust-lang.org/2015/05/15/Rust-1.0/), and the language is now
used for command-line tools, network services, embedded software, WebAssembly,
and performance-sensitive parts of larger applications.

This repository uses Rust to implement a small native Convex client. It is an
educational, unofficial demonstration, not a production SDK and not an official
Convex or Rust project.

## Getting Started

Start with the [canonical basic example](examples/basics/main.rs). It reads a
counter, opens a Live subscription, applies a mutation, and checks that the
reactive update agrees with the mutation result.

From the repository root, Docker builds and runs that exact program against a
dedicated verification deployment:

```sh
./run verify-example rust
```

You do not need a Rust toolchain installed on the host.

## Interesting Parts

### A Live update arrives in a mailbox, not a hook

React's `useQuery` opens a subscription when a component mounts and tears it
down when it unmounts, all invisibly. This client has no component tree to
hook into, so a Live query becomes an explicit resource instead: call
`subscribe`, then block on a bounded mailbox whenever you want the next value.

```rust
let live = client.subscribe("demo:state", json!({"room": room}))?;

// TypeScript: `useQuery(api.demo.state, { room })` does this invisibly.
let initial = live.updates().recv_timeout(Duration::from_secs(10))?;
if let Some(error) = initial.error {
    panic!("initial Live error: {error}");
}
println!("live initial count: {}", initial.value.unwrap()["count"]);

live.close()?; // nothing unsubscribes until you say so
```

The mailbox only keeps the newest 16 updates, so a command-line consumer that
falls behind stays bounded instead of piling up an unread backlog forever.

### A rejected call is a value, not a thrown exception

Rust has no exceptions. Every fallible call in this client returns
`Result<T, Error>`, and `Error` is a plain enum, so the ways a Convex call can
fail are written down as a type instead of left implicit.

```rust
pub enum Error {
    Function(FunctionError), // the Convex function itself rejected the call
    Protocol(String),        // a server response this client can't parse
    Transport(String),       // reqwest/tungstenite couldn't reach the deployment
    Closed,                  // client.close() already ran
}

// TypeScript: an uncaught throw crashes the app; `?` here just returns early.
let mutation = client.mutation("demo:increment", json!({"room": room}))?;
```

Match on `Error::Function` to read Convex's own `message` and `data` back out;
every other variant is this client admitting the network or protocol misbehaved.

### Types don't exist until serde decodes them

Convex's generated TypeScript API carries a query's result type all the way
into the component. This client isn't typed against your schema at all — it
passes `serde_json::Value` around until the moment you ask `serde` to turn it
into a struct.

```rust
#[derive(Deserialize)]
struct State {
    count: f64, // Convex may send 1 or 1.0 -- this is where the field becomes typed.
}

let result = client.query("demo:state", json!({"room": room}))?;
let state: State = serde_json::from_value(result.value)?;
println!("{}", state.count);
```

Everything before that last `from_value` call is just JSON; decoding is the
one place `State` becomes real.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and bearer-token replacement | Verified by shared local and hosted conformance |
| Live query snapshots, updates, unsubscribe, and reconnect | Verified by shared local and hosted conformance |
| Live authentication and optimistic writes | Deferred |

## Example

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

## Implementation Notes

This is a native Rust implementation. It uses blocking `reqwest` calls with
Rustls for Convex's documented HTTP endpoints, `serde_json` for values, and
`tungstenite` for Live WebSocket transport. Convex-specific request, response,
subscription, and reconnect behaviour is implemented in
[`client/lib.rs`](client/lib.rs), not delegated to another Convex client.

One owner thread is solely responsible for the Live socket and active query
set. Other threads send it commands, which avoids concurrent reads and writes
on the same connection. Each subscription receives updates through a bounded
mailbox. Dropping a subscription also requests cleanup, while the example calls
`close` explicitly so the lifecycle is obvious to a reader.

The Docker build pins Rust 1.89.0 and produces static `linux/amd64` binaries.
The final images contain the example or adapter, certificates, and only the
small shell surface required by the shared verifier. They run as user
`65532:65532`; Cargo, `rustc`, package managers, Node.js, and Python are absent.

For the repository's test layers, `./run test rust` checks formatting, unit
tests, compilation, and target architecture inside Docker. The Getting Started
command executes the canonical example. `./run verify rust` and
`./run verify-hosted rust` are the separate shared conformance profiles used by
the recorded capability evidence.

## Known Issues

1. Live follows a pinned, unversioned sync profile. `TransitionChunk` assembly,
   Live authentication, optimistic updates, and WebSocket mutations or actions
   are not implemented.
2. The public value surface is JSON-only. Convex-specific values outside the
   JSON-safe subset do not receive dedicated Rust types or codecs.
3. Each Live subscription keeps only its newest 16 updates. If a consumer falls
   behind, older intermediate states are dropped while the newest state is kept.
