<img src="logo.png" alt="C++ logo" width="120">
<!-- Logo source: https://github.com/isocpp/logos/blob/master/cpp_logo.png -->

# C++

C++ is a general-purpose, ISO-standardized language with a strong bias toward systems programming. Bjarne Stroustrup began the work in 1979 as "C with Classes", and the name C++ arrived in 1983. It grew from C while adding abstractions such as classes, templates, deterministic cleanup, and a large standard library.

Today C++ remains a mainstream choice for software where performance, portability, and control over resources matter, including operating systems, game engines, browsers, embedded systems, and developer infrastructure. The [Standard C++ Foundation website](https://isocpp.org/) is the best starting point for the language and its current ecosystem.

This client is an educational, unofficial demonstration. It is not a production SDK and is not supported by Convex.

## Getting Started

The canonical [`examples/basics/main.cc`](examples/basics/main.cc) queries a counter, starts a Live subscription before writing, sends an idempotent mutation, and reads the resulting Live update.

From the repository root, run:

```sh
./run verify-example cpp
```

The command builds and runs the exact example in Docker against a unique test room. You do not need a C++ toolchain installed on your host.

## Interesting Parts

### Braces that read like a JSON literal

C++11 added uniform initialization, and it let libraries overload `{ ... }` lists — so `nlohmann::json` (aliased here as `convex::Json`) makes argument-building look like the JSON it produces. Reading a field back goes through a member function template: you name the C++ type you want, right at the call site.

```cpp
// TypeScript: const state = useQuery(api.demo.state, { room: "readme-cpp" });
const auto result = client.query("demo:state", {{"room", "readme-cpp"}});

// .get<T>() is a template: you pick the static type here, and the
// JSON-to-int conversion is checked at this exact boundary.
const int count = result.value.at("count").get<int>();
```

No generated types, no schema file — the braces *are* the argument object, and `get<int>()` is the one line where dynamic JSON becomes an ordinary typed value.

### The destructor is your unmount handler

RAII — "resource acquisition is initialization" — is C++'s signature idea, designed by Stroustrup in the 1980s: cleanup code lives in destructors, so leaving a scope is what releases a resource. Here that means the client and every Live subscription tear down their own transports the moment they go out of scope.

```cpp
{
  convex::Client client(url);  // opens transports
  auto subscription = client.subscribe("demo:state", {{"room", "readme-cpp"}});
  // ... query, mutate, read Live updates ...
}   // scope ends: ~Subscription stops its worker, ~Client closes transports
// TypeScript: React's useEffect cleanup does this for you on unmount.
```

Explicit `close()` calls exist for when you want to control the timing — but you cannot forget the destructor version, because the compiler inserts it.

### A Live update is a `std::optional`, not a callback

A private worker thread owns the WebSocket and handles reconnects; your thread simply *pulls* the next value when it wants one. `next_update()` blocks up to a timeout, and its return type — `std::optional<Update>`, a C++17 vocabulary type — makes "nothing arrived in time" a distinct state you must inspect, not a null pointer or a sentinel.

```cpp
auto subscription = client.subscribe("demo:state", {{"room", "readme-cpp"}});

// Blocks until the worker delivers a value, or 10 seconds pass.
const std::optional<convex::Update> update = subscription->next_update();
if (update && update->error.empty()) {
  // TypeScript: useQuery pushes re-renders; here you pull each value.
  std::cout << update->value.at("count").get<int>() << '\n';
}
```

Same reactive Convex query underneath — the push-vs-pull difference is just who owns the event loop, and in a command-line program that's you.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, and action | Verified by shared local and hosted conformance |
| Live subscription and reconnect | Verified by shared local and hosted conformance |

The checked-in evidence awarded both the `http` and `live` capabilities after local and hosted conformance passed 31/31. `./run test cpp` covers formatting, compilation, and language-local tests in Docker. The repository's shared evidence gates are `./run verify cpp` and `./run verify-hosted cpp`.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.cc -->
```cpp
#include "convex.hpp"

#include <cstdlib>
#include <iostream>
#include <random>

// Give the mutation an idempotency key that is unique to this example run. If
// the request were retried, Convex could identify the same logical write.
static std::string run_id() {
  std::random_device random;
  return std::to_string(random()) + std::to_string(random());
}

int main(int argc, char **argv) {
  try {
    // Use the deployment selected by the verifier. This public counter does not
    // require authentication, so the example does not need an auth token.
    const char *url = std::getenv("CONVEX_URL");
    if (!url) {
      throw std::runtime_error("CONVEX_URL is required");
    }

    // Create the Convex client and select a unique room supplied by the shared
    // verifier. Both objects clean up their transports when they leave scope.
    convex::Client client(url);
    const std::string room = argc > 1 ? argv[1] : "cpp-example";

    // Query the current room over Convex's documented HTTP API, then decode its
    // JSON count into an ordinary, type-checked C++ integer.
    const auto current = client.query("demo:state", {{"room", room}});
    const int count = current.value.at("count").get<int>();
    if (count != 0) {
      throw std::runtime_error("initial HTTP count was not zero");
    }
    std::cout << "current count: " << count << '\n';

    // Start Live before the mutation so no state change can be missed. Its
    // initial value must agree with the HTTP query before we continue.
    auto subscription = client.subscribe("demo:state", {{"room", room}});
    const auto initial = subscription->next_update();
    if (!initial || !initial->error.empty() ||
        initial->value.at("count").get<int>() != count) {
      throw std::runtime_error("Live initial count differed from HTTP");
    }
    std::cout << "live initial count: " << count << '\n';

    // Apply one idempotent mutation over HTTP and require the expected 0 -> 1
    // result before trusting it or printing the next transcript lines.
    const auto mutation = client.mutation(
        "demo:increment",
        {{"room", room}, {"language", "cpp"}, {"runId", run_id()}});
    if (!mutation.value.at("applied").get<bool>()) {
      throw std::runtime_error("mutation was not applied");
    }
    std::cout << "mutation applied: true\n";

    const int changed = mutation.value.at("state").at("count").get<int>();
    if (changed != 1) {
      throw std::runtime_error("mutation count was not one");
    }
    std::cout << "mutation count: " << changed << '\n';

    // The next Live value must describe that same mutation. Only after HTTP and
    // Live agree do we report the universal happy-path verification line.
    const auto updated = subscription->next_update();
    if (!updated || !updated->error.empty() ||
        updated->value.at("count").get<int>() != changed) {
      throw std::runtime_error("Live update was unexpected");
    }
    std::cout << "live updated count: " << changed << '\n';
    subscription->close();

    std::cout << "verified count: " << count << " -> " << changed << '\n';
    client.close();
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native C++20 client. It implements Convex-specific request and response handling itself, while Boost.Beast and OpenSSL provide ordinary HTTP, WebSocket, and TLS transport. `nlohmann/json` represents arguments, returned values, logs, and structured function errors.

`convex::Client` and `convex::Subscription` use deterministic C++ cleanup: their destructors close the transports they own, while explicit `close()` calls let an application control when shutdown happens. HTTP operations open a request, decode the response, and return synchronously. Live uses one private worker per subscription so reads, reconnects, and query state have a single owner.

The Live implementation targets the reviewed `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`. It validates complete state transitions before publishing an update, reconnects with bounded exponential backoff, and carries forward the greatest valid server timestamp. Each subscription keeps at most 16 pending updates; if a consumer falls behind, it drops the oldest so newer state remains available. The `debugDisconnect` operation exists only in the conformance adapter, not in the educational client API.

## Known Issues

1. Live targets a pinned experimental protocol profile. This demonstration does not promise compatibility with future Convex protocol changes.
2. Live authentication, actions over WebSocket, transition chunk assembly, optimistic updates, and mutation replay are not implemented.
3. Values are limited to the JSON types supported by `nlohmann/json`, and a slow Live consumer can miss intermediate updates when the 16-item queue overflows.
