use convex_rust_demo::Client;
use serde_json::json;
use std::{env, time::Duration};

fn main() {
    let url = env::var("CONVEX_URL").expect("CONVEX_URL is required");
    let room = env::args().nth(1).unwrap_or_else(|| "rust-example".into());

    // Create the native Rust client for the configured Convex deployment.
    let client = Client::new(&url).expect("create client");
    // Query the counter over Convex's documented HTTP endpoint.
    let current = client.query("demo:state", json!({"room": room})).expect("current query");
    let before = current.value["count"].as_i64().expect("count");
    println!("current count: {before}");

    // Start Live before mutating, so the initial snapshot and the later change
    // prove this is a real reactive subscription rather than HTTP polling.
    let live = client.subscribe("demo:state", json!({"room": room})).expect("start Live");
    let initial = live.updates().recv_timeout(Duration::from_secs(10)).expect("initial Live value");
    if let Some(error) = initial.error { panic!("initial Live error: {error}"); }
    assert_eq!(initial.value.expect("initial value")["count"].as_i64(), Some(before));
    println!("live initial count: {before}");

    // Use a unique idempotency key so this mutation is safe if the example is retried.
    let mutation = client.mutation("demo:increment", json!({"room": room, "language":"rust", "runId":uuid::Uuid::new_v4().to_string()})).expect("increment");
    assert_eq!(mutation.value["applied"], true);
    let after = mutation.value["state"]["count"].as_i64().expect("mutation count");
    assert_eq!(after, before + 1);
    println!("mutation applied: true");
    println!("mutation count: {after}");

    // Read the resulting Live update and fail if it disagrees with the mutation.
    let updated = live.updates().recv_timeout(Duration::from_secs(10)).expect("updated Live value");
    if let Some(error) = updated.error { panic!("updated Live error: {error}"); }
    assert_eq!(updated.value.expect("updated value")["count"].as_i64(), Some(after));
    println!("live updated count: {after}");
    println!("verified count: {before} -> {after}");
    let _ = live.close();
    let _ = client.close();
}
