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
educational, unofficial demonstration, not a production SDK or a project
endorsed by Convex or the Rust project.

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

### The type system stops at the JSON boundary

Convex's generated TypeScript API carries the result type into a React
component. This Rust client deliberately returns `serde_json::Value`, so Rust
can check a decoded struct but cannot infer its shape from the Convex function.

**TypeScript with React**

```tsx
import { ConvexProvider, ConvexReactClient, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL);

function RoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-rust" });
  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // `state` and `count` are type-safe here.
}

export function App() {
  return (
    <ConvexProvider client={convex}>
      <RoomCount />
    </ConvexProvider>
  );
}
```

**Rust**

```rust
use convex_rust_demo::Client;
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
struct State {
    count: f64, // Decoding is where this JSON field becomes type-checked.
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let deployment = std::env::var("CONVEX_URL")?;
    let client = Client::new(&deployment)?;
    let result = client.query("demo:state", json!({ "room": "readme-rust" }))?;
    let state: State = serde_json::from_value(result.value)?;
    println!("{}", state.count);
    client.close()?;
    Ok(())
}
```

The Rust call is a one-off HTTP query, not the equivalent of React's reactive
`useQuery` hook. The [full example](examples/basics/main.rs) also handles the
fact that a whole Convex number may be encoded as either `1` or `1.0`.

### A Live subscription is a resource you own

React starts and stops a query subscription with the component lifecycle. The
Rust API instead exposes a subscription and a blocking `recv_timeout` mailbox.
That blocking shape is a choice made by this small client, not a limitation of
Rust, which also supports callbacks, channels, and async streams.

**TypeScript with React**

```tsx
import {
  ConvexProvider,
  ConvexReactClient,
  useMutation,
  useQuery,
} from "convex/react";
import { api } from "../convex/_generated/api";

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL);

function Counter() {
  const room = "readme-live-rust";
  const state = useQuery(api.demo.state, { room }); // React owns the subscription.
  const increment = useMutation(api.demo.increment);
  const addOne = () =>
    increment({ room, language: "typescript", runId: crypto.randomUUID() });

  return <button onClick={() => void addOne()}>{state?.count ?? "Loading..."}</button>;
}

export function App() {
  return (
    <ConvexProvider client={convex}>
      <Counter />
    </ConvexProvider>
  );
}
```

**Rust**

```rust
use convex_rust_demo::Client;
use serde_json::json;
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let deployment = std::env::var("CONVEX_URL")?;
    let room = "readme-live-rust";
    let client = Client::new(&deployment)?;
    let live = client.subscribe("demo:state", json!({ "room": room }))?;

    // This client exposes the next reactive value through a blocking mailbox.
    let initial = live.updates().recv_timeout(Duration::from_secs(10))?;
    if let Some(error) = initial.error {
        return Err(Box::new(error));
    }
    println!("initial: {}", initial.value.expect("initial value")["count"]);

    let mutation = client.mutation(
        "demo:increment",
        json!({
            "room": room,
            "language": "rust",
            "runId": uuid::Uuid::new_v4().to_string()
        }),
    )?;
    println!("mutation: {}", mutation.value["state"]["count"]);

    // The next mailbox item is the reactive result of that mutation.
    let updated = live.updates().recv_timeout(Duration::from_secs(10))?;
    if let Some(error) = updated.error {
        return Err(Box::new(error));
    }
    println!("updated: {}", updated.value.expect("updated value")["count"]);

    live.close()?; // Explicitly remove the query before stopping its owner loop.
    client.close()?;
    Ok(())
}
```

The owned subscription makes cleanup and timeout policy visible. Its mailbox
keeps the newest 16 updates, so a slow command-line consumer stays bounded but
may not observe every intermediate value.

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
