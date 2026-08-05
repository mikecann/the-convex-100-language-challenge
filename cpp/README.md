# Convex from C++

This is a small C++ demonstration of Convex's JSON HTTP API and an experimental pinned Live protocol profile.

It is educational, unofficial, and not a production SDK.

## Start here

[`examples/basics/main.cpp`](examples/basics/main.cpp) walks through a counter query, a subscription started before the write, an idempotent mutation, and the resulting Live update.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, and action | Pending shared conformance |
| Live subscription and reconnect | Pending shared conformance |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.cpp -->
```text
#include "convex.hpp"
#include <cstdlib>
#include <iostream>
#include <random>

static std::string run_id() { std::random_device random; return std::to_string(random()) + std::to_string(random()); }
int main(int argc, char** argv) {
  try {
    const char* url = std::getenv("CONVEX_URL"); if (!url) throw std::runtime_error("CONVEX_URL is required");
    // Create a Convex client using the deployment selected by the verifier.
    convex::Client client(url); const std::string room = argc > 1 ? argv[1] : "cpp-example";
    // Query the current room state over Convex's documented HTTP API.
    auto current = client.query("demo:state", {{"room", room}}); int count = current.value.at("count").get<int>(); std::cout << "current count: " << count << '\n';
    // Start Live before the mutation, then require its initial snapshot to
    // agree with the HTTP query so no state change can be silently missed.
    auto subscription = client.subscribe("demo:state", {{"room", room}});
    auto initial = subscription->next_update(); if (!initial || !initial->error.empty()) throw std::runtime_error("Live initial value failed");
    if (initial->value.at("count").get<int>() != count) throw std::runtime_error("Live initial count differed from HTTP");
    std::cout << "live initial count: " << count << '\n';
    // The random runId is the mutation idempotency key for this logical write.
    auto mutation = client.mutation("demo:increment", {{"room", room}, {"language", "cpp"}, {"runId", run_id()}}); if (!mutation.value.at("applied").get<bool>()) throw std::runtime_error("mutation was not applied"); std::cout << "mutation applied: true\n";
    int changed = mutation.value.at("state").at("count").get<int>(); if (changed != count + 1) throw std::runtime_error("mutation count was unexpected"); std::cout << "mutation count: " << changed << '\n';
    // The next Live value must reflect that same mutation before reporting success.
    auto updated = subscription->next_update(); if (!updated || !updated->error.empty() || updated->value.at("count").get<int>() != changed) throw std::runtime_error("Live update was unexpected");
    std::cout << "live updated count: " << changed << '\n'; subscription->close();
    std::cout << "verified count: " << count << " -> " << changed << '\n'; client.close(); return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test cpp` builds and tests the client wholly inside Docker. `./run verify-example cpp`, `./run verify cpp`, and `./run verify-hosted cpp` are root-owned evidence gates and have not yet awarded a capability.

## Protocol notes

The client uses ordinary Boost.Beast/OpenSSL transport code. Live is constrained to the reviewed `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`; `debugDisconnect` is adapter-only.

## Limitations

This experiment does not promise protocol compatibility. Authentication for Live, transition chunk assembly, optimistic updates, replay, and the full Convex value space are deferred.
