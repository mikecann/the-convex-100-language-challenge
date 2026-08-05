# Convex from PHP

This demonstration uses PHP streams to call Convex's documented JSON HTTP API
and a small native RFC6455 transport for reactive queries.

It is educational and unofficial, not a production SDK or a package for publication.

## Start here

[`examples/basics/main.php`](examples/basics/main.php) reads a counter, begins
Live, applies one idempotent increment, and confirms the same `0 -> 1` update.
The block is generated from that exact runnable source.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared verification | Native JSON query, mutation, action, bearer auth, logs, and structured errors. |
| Live | Awaiting shared verification | Native WebSocket query-set Add/Remove, reconnect, recovery, and clean close. |

No badge is earned until local and hosted black-box verification passes.

## The basic example

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

## Verify it in Docker

```sh
./run test php
./run verify-example php
./run verify php
./run verify-hosted php
```

`test` runs PHP parsing and local tests in Docker. The later commands execute
the exact example and shared HTTP/Live protocol checks against approved targets.

## Conformance and protocol notes

The test-only adapter implements NDJSON v1 over stdin/stdout or `ADAPTER_LISTEN`
TCP. `debugDisconnect` is adapter-only. Live pins the unversioned `/api/sync`
profile at Convex Rust `0.10.4` commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`.

## Limitations

- Live authentication and TransitionChunk assembly are deferred.
- JSON-safe values are supported, not lossless Int64, bytes, special floats, or negative zero.
- The per-subscription delivery queue retains the newest 16 updates for a slow consumer.
