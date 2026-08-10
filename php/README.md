<img src="logo.png" alt="PHP logo" width="180">
<!-- Logo source: https://www.php.net/images/logos/new-php-logo.png -->

# PHP

[PHP](https://www.php.net/) is a general-purpose scripting language built for
the web. [Rasmus Lerdorf created its first form in
1994](https://www.php.net/manual/en/history.php.php), and later versions grew
into the open-source language used for server-rendered sites, content systems,
web applications, and command-line scripts. Its C-influenced syntax will look
familiar to Java, C#, and JavaScript developers, while its `$variables` and
[flexible arrays](https://www.php.net/manual/en/language.types.array.php) give
it a character of its own.

This repository's PHP client is an educational, unofficial demonstration. It
is not a production SDK and is not a package intended for publication.

## Getting Started

Start with [`examples/basics/main.php`](examples/basics/main.php). It reads a
counter, opens a Live subscription, applies one idempotent increment, and sees
the counter move from `0` to `1` through that subscription.

From the repository root, Docker builds the PHP example and runs that exact
source against the project's approved test deployment:

```sh
./run verify-example php
```

## Interesting Parts

### One PHP array does the jobs of object and dictionary

React gets a generated TypeScript type for both the arguments and returned
state. This PHP client decodes JSON objects into PHP associative arrays, which
are ordered maps indexed with string keys.

**TypeScript with React**

```tsx
import { ConvexProvider, ConvexReactClient, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL);

export function Counter() {
  return (
    <ConvexProvider client={convex}>
      <CounterValue />
    </ConvexProvider>
  );
}

function CounterValue() {
  const room = "php-readme";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <span>Loading...</span>;
  return <output>{state.count}</output>; // state and count are type-safe here.
}
```

**PHP**

```php
<?php
declare(strict_types=1);

require __DIR__ . "/client/convex.php";

use Convex\Client;

$convexUrl = getenv("CONVEX_URL");
if ($convexUrl === false || $convexUrl === "") {
    throw new RuntimeException("CONVEX_URL is required");
}

$client = new Client($convexUrl);
$room = "php-readme";

try {
    // `room` and the decoded state are associative arrays at runtime.
    $state = $client->query("demo:state", ["room" => $room])->value;
    echo $state["count"];
} finally {
    $client->close();
}
```

The PHP call is a one-off HTTP query, not a reactive equivalent of `useQuery`.
Also, `Result::$value` is `mixed`, so this client leaves result-shape checking
to application code rather than generating PHP types from the Convex API.

### React owns reactivity; this CLI owns the subscription

In React, `useQuery` subscribes during the component's lifetime and rerenders
when the value changes. The PHP language supports callbacks, generators, and
Fibers, but this small client deliberately exposes `nextUpdate()` as a blocking
operation. That choice keeps ownership visible in a command-line program.

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

export function IncrementButton() {
  return (
    <ConvexProvider client={convex}>
      <IncrementButtonBody />
    </ConvexProvider>
  );
}

function IncrementButtonBody() {
  const room = "php-readme";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function handleIncrement() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The mutation result is typed too.
  }

  return (
    <button onClick={handleIncrement} disabled={state === undefined}>
      Count: {state?.count ?? "..."}
    </button>
  );
}
```

**PHP**

```php
<?php
declare(strict_types=1);

require __DIR__ . "/client/convex.php";

use Convex\Client;

$convexUrl = getenv("CONVEX_URL");
if ($convexUrl === false || $convexUrl === "") {
    throw new RuntimeException("CONVEX_URL is required");
}

$client = new Client($convexUrl);
$room = "php-readme";

try {
    // Subscribe before mutating so this command-line process cannot miss the update.
    $live = $client->subscribe("demo:state", ["room" => $room]);
    $initial = $live->nextUpdate(10); // Blocks until the initial state arrives.
    if ($initial->error !== null) {
        throw $initial->error;
    }

    $result = $client->mutation("demo:increment", [
        "room" => $room,
        "language" => "php",
        "runId" => bin2hex(random_bytes(8)),
    ])->value;
    echo $result["state"]["count"], PHP_EOL; // Decode the returned array directly.

    $changed = $live->nextUpdate(10); // Explicitly wait for the reactive value.
    if ($changed->error !== null) {
        throw $changed->error;
    }
    echo $changed->value["count"], PHP_EOL;
    $live->close();
} finally {
    $client->close();
}
```

The explicit `close()` calls matter because this process, rather than a React
component lifecycle, owns the socket and subscription.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native JSON query, mutation, action, bearer auth, logs, and structured errors. |
| Live | Verified by shared local and hosted conformance | Native WebSocket query-set Add/Remove, reconnect, recovery, and clean close. |

Local and hosted black-box verification passed, earning HTTP and Live.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.php -->
```php
#!/usr/local/bin/php
<?php
declare(strict_types=1);

$clientPath = getenv("CONVEX_CLIENT_PATH") ?:
    dirname(__DIR__, 2) . "/client/convex.php";
require $clientPath;

use Convex\Client;

// Convert a JSON number into the integer counter used by this example.
function whole(mixed $value, string $where): int
{
    if (
        !is_int($value) &&
        !(is_float($value) && is_finite($value) && floor($value) === $value)
    ) {
        throw new RuntimeException("$where count was not a whole number");
    }
    return (int) $value;
}

// Connect using the verifier's dedicated deployment, never a personal project.
$convexUrl = getenv("CONVEX_URL");
if ($convexUrl === false || $convexUrl === "") {
    throw new RuntimeException("CONVEX_URL is required");
}
$client = new Client($convexUrl);

// A unique room keeps this example independent when several clients run together.
$room = $argv[1] ?? "php-example";

try {
    // Read the current counter through Convex's documented JSON HTTP query API.
    $current = whole(
        $client->query("demo:state", ["room" => $room])->value["count"],
        "current query",
    );
    echo "current count: $current\n";

    // Start Live before writing, so the subscription cannot miss this mutation.
    $live = $client->subscribe("demo:state", ["room" => $room]);
    $initial = $live->nextUpdate(10);
    if ($initial->error) {
        throw $initial->error;
    }
    $initialCount = whole($initial->value["count"], "initial Live value");
    if ($initialCount !== $current) {
        throw new RuntimeException("Live initial value disagreed");
    }
    echo "live initial count: $initialCount\n";

    // The random runId is the mutation's idempotency key for one logical increment.
    $mutation = $client->mutation("demo:increment", [
        "room" => $room,
        "language" => "php",
        "runId" => bin2hex(random_bytes(8)),
    ])->value;
    if (($mutation["applied"] ?? false) !== true) {
        throw new RuntimeException("mutation was not applied");
    }
    echo "mutation applied: true\n";
    $after = whole($mutation["state"]["count"], "mutation");
    if ($after !== $current + 1) {
        throw new RuntimeException("mutation count was unexpected");
    }
    echo "mutation count: $after\n";

    // Live must now deliver the same changed state, without another HTTP read.
    $changed = $live->nextUpdate(10);
    if ($changed->error) {
        throw $changed->error;
    }
    $changedCount = whole($changed->value["count"], "updated Live value");
    if ($changedCount !== $after) {
        throw new RuntimeException("Live update disagreed");
    }
    echo "live updated count: $changedCount\n";

    // Only print the universal final line after every HTTP and Live assertion passed.
    echo "verified count: $current -> $changedCount\n";
    $live->close();
} finally {
    $client->close();
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The client is native PHP 8.4.8 and has no third-party runtime dependencies. For
queries, mutations, and actions, it builds JSON requests and sends them through
PHP's built-in stream functions. Responses retain Convex log lines and turn
function failures into `FunctionError` objects with their structured data.

Live uses a small RFC 6455 WebSocket implementation over PHP streams. The
public API is synchronous: `nextUpdate()` pumps the socket until an update,
error, or timeout arrives. Each subscription retains the newest 16 updates, so
a slow consumer has a deliberate bound instead of an ever-growing queue.

The test-only conformance adapter speaks NDJSON v1 over standard input/output or
an `ADAPTER_LISTEN` TCP connection. Its `debugDisconnect` command is not part of
the educational client API. Live targets the unversioned `/api/sync` behaviour
pinned to Convex Rust `0.10.4` commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`; it should not be read as a promise
that this undocumented profile is stable.

For the repository's Docker layers:

```sh
./run test php
./run verify-example php
./run verify php
./run verify-hosted php
```

`test` parses every PHP source file and runs the language-local fixtures.
`verify-example` executes the canonical example. `verify` and `verify-hosted`
add shared HTTP and Live conformance against the approved local and hosted
targets respectively.

## Known Issues

1. Live authentication, optimistic writes, and `TransitionChunk` assembly are
   deferred.
2. Values are limited to JSON-safe data. The client does not preserve Convex
   Int64, bytes, special floating-point values, or negative zero losslessly.
3. A slow Live consumer keeps only the newest 16 queued updates, so intermediate
   states can be discarded while the latest state is retained.
