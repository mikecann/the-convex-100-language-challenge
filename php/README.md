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

### One array shape is list, map, and JSON payload at once

PHP ships with exactly one native collection type. The `array` is an ordered
map that happily plays list, dictionary, and struct depending on how you index
it — there's no separate object-literal syntax the way JavaScript has one.
Convex arguments go out through this same associative array, and decoded JSON
comes back through it too.

```php
$room = "php-readme";
$state = $client->query("demo:state", ["room" => $room])->value;
echo $state["count"];                        // TypeScript: state.count — a generated, typed field

$result = $client->mutation("demo:increment", [
    "room" => $room,
    "language" => "php",
    "runId" => bin2hex(random_bytes(8)),
])->value;
echo $result["state"]["count"];
```

### A class body that fits inside its own constructor

PHP 8.0 (2020) added constructor property promotion: a parameter list can
double as a typed property list. No repeated `private $value;` declarations,
no `$this->value = $value;` assignments — the client's small value types
collapse to one short block each.

```php
final class Update
{
    // TypeScript: this fuses an `interface Update {...}` with its constructor.
    public function __construct(
        public mixed $value = null,
        public ?Error $error = null,
        public array $logs = [],
    ) {}
}
```

### `?->` and `??=` keep an unopened socket honest

The Live connection is optional and lazy — nothing opens a WebSocket until the
first `subscribe()` call. PHP's null-coalescing assignment `??=` and nullsafe
operator `?->` let the code say "build it once, then call through it if it
exists" without an `if ($this->live === null)` at every touchpoint.

```php
public function subscribe(string $path, array $args = []): Subscription
{
    $this->validate($path, $args);
    $this->guard();
    // ??= builds the LiveManager, and opens the socket, only on first use.
    return ($this->live ??= new LiveManager($this->url, $this->version))
        ->subscribe($path, $args);
}

public function pump(float $timeout = 0.0): void
{
    $this->live?->pump($timeout); // TypeScript: the same shrug as `this.live?.pump(t)`
}
```

### `nextUpdate()` turns reactivity into a single blocking call

PHP has no event loop the way a browser tab does, so this client doesn't fake
`useQuery`'s automatic rerenders. Instead `Subscription::nextUpdate()` blocks
the calling script, pumping the raw WebSocket until a Live update, an error,
or a timeout arrives.

```php
$live = $client->subscribe("demo:state", ["room" => $room]);
$initial = $live->nextUpdate(10); // TypeScript: useQuery just rerenders — no polling call
if ($initial->error !== null) {
    throw $initial->error;
}
echo $initial->value["count"];
$live->close();
```

Reactivity becomes a question the script asks on its own schedule, not a
stream it's swept along by.

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
