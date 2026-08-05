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
