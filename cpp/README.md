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

### Turning JSON into an ordinary typed value

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function RoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-cpp" });
  if (state === undefined) return <p>Loading...</p>;

  console.log(state.count); // The generated API makes count a number here.
  return <p>{state.count}</p>;
}
```

**C++**

```cpp
#include "convex.hpp"

#include <cstdlib>
#include <iostream>
#include <stdexcept>

int main() {
  const char *url = std::getenv("CONVEX_URL");
  if (!url) {
    throw std::runtime_error("CONVEX_URL is required");
  }
  convex::Client client(url); // The destructor also closes transports.

  // C++ builds the named Convex arguments as a JSON object.
  const convex::Json args{{"room", "readme-cpp"}};
  const auto result = client.query("demo:state", args);

  // Check the JSON shape and convert count at the application boundary.
  const int count = result.value.at("count").get<int>();
  std::cout << count << '\n';
}
```

The React hook is reactive and generated TypeScript types describe its result. This C++ call is a one-off HTTP query. The client returns `nlohmann::json`, so application code chooses where to validate and convert fields into C++ types. See the small public surface in [`client/convex.hpp`](client/convex.hpp).

### Owning a Live subscription explicitly

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function LiveRoomCount() {
  // React starts, updates, and disposes this subscription with the component.
  const state = useQuery(api.demo.state, { room: "readme-cpp-live" });
  return <p>{state?.count ?? "Loading..."}</p>;
}
```

**C++**

```cpp
#include "convex.hpp"

#include <cstdlib>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>

// Create a fresh idempotency key for this logical mutation attempt.
static std::string run_id() {
  std::random_device random;
  return std::to_string(random()) + std::to_string(random());
}

int main() {
  const char *url = std::getenv("CONVEX_URL");
  if (!url) {
    throw std::runtime_error("CONVEX_URL is required");
  }
  convex::Client client(url);
  const convex::Json query_args{{"room", "readme-cpp-live"}};

  // This command-line client owns the subscription and waits for each value.
  auto subscription = client.subscribe("demo:state", query_args);
  const auto initial = subscription->next_update();
  if (!initial || !initial->error.empty()) {
    throw std::runtime_error("initial Live value failed");
  }
  const int before = initial->value.at("count").get<int>();

  // A unique runId makes a retried increment refer to the same logical write.
  const convex::Json mutation_args{{"room", "readme-cpp-live"},
                                   {"language", "cpp"},
                                   {"runId", run_id()}};
  const auto mutation = client.mutation("demo:increment", mutation_args);
  const bool applied = mutation.value.at("applied").get<bool>();

  // next_update blocks until a value arrives or its timeout expires.
  const auto changed = subscription->next_update();
  if (!changed || !changed->error.empty()) {
    throw std::runtime_error("updated Live value failed");
  }
  const int after = changed->value.at("count").get<int>();
  std::cout << before << " -> " << after << ", applied: " << std::boolalpha
            << applied << '\n';
  subscription->close(); // React normally performs this lifecycle step.
}
```

C++ supports callbacks, futures, coroutines, and other asynchronous styles. The blocking `next_update()` operation is a deliberate choice in this tiny client, not a limitation of C++. It keeps the teaching example linear while a private worker thread owns the WebSocket and reconnects.

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
