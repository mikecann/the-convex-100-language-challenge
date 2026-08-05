<?php
declare(strict_types=1);
/* Real loopback tests use a separate PHP process for the scripted peer. This
 * keeps every production socket call real without requiring host tooling. */
require __DIR__ . "/convex.php";
use Convex\{Client, FunctionError, Subscription, Update};
function ok(bool $v, string $m): void
{
    if (!$v) {
        throw new RuntimeException($m);
    }
}
function port(): int
{
    $s = stream_socket_server("tcp://127.0.0.1:0", $n, $e);
    $p = (int) substr(strrchr(stream_socket_get_name($s, false), ":"), 1);
    fclose($s);
    return $p;
}
function peer(string $role, int $port): array
{
    $pipes = [];
    $p = proc_open(
        [PHP_BINARY, __DIR__ . "/fixture_server.php", $role, (string) $port],
        [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
        $pipes,
    );
    usleep(100000);
    return [$p, $pipes];
}
// A real HTTP endpoint proves JSON nesting, UTF-8, logs, and structured errors.
$hp = port();
[$p, $pipes] = peer("http", $hp);
$client = new Client("http://127.0.0.1:$hp");
$r = $client->query("demo:echo", ["value" => ["é"]]);
ok(
    $r->value["nested"]["utf8"] === "é" && $r->logs === ["ok"],
    "HTTP result/logs",
);
try {
    $client->query("demo:fail", []);
    throw new RuntimeException("flattened error");
} catch (FunctionError $e) {
    ok(
        $e->data["code"] === "ROOM_EMPTY" && $e->logs === ["failed"],
        "structured HTTP error",
    );
}
proc_close($p);
// RFC6455 peer records Connect/Add/Remove and sends fragmented UTF-8
// QueryFailed, followed by QueryUpdated for the exact same query id.
$wp = port();
[$p, $pipes] = peer("websocket", $wp);
$live = new Client("http://127.0.0.1:$wp");
$sub = $live->subscribe("demo:requiresNonzero", ["room" => "r"]);
$first = $sub->nextUpdate(3);
ok(
    $first->error instanceof FunctionError &&
        $first->error->data["code"] === "ROOM_EMPTY",
    "QueryFailed",
);
$second = $sub->nextUpdate(3);
ok(
    $second->value["count"] === 1 && $second->value["word"] === "é",
    "same-subscription recovery",
);
$sub->close();
$live->close();
proc_close($p);
// Six successive sockets are intentionally closed by the server. Each fresh
// transport must report connectionCount 0..5 and re-send Add. The peer checks
// those bytes and the final Remove version transition before exiting cleanly.
$wp = port();
[$p, $pipes] = peer("reconnect", $wp);
$live = new Client("http://127.0.0.1:$wp");
$sub = $live->subscribe("demo:state", ["room" => "r"]);
for ($i = 0; $i < 6; $i++) {
    $u = $sub->nextUpdate(4);
    ok($u->error === null && $u->value["count"] === $i, "reconnect value $i");
}
$sub->close();
$live->close();
ok(proc_close($p) === 0, "five reconnect Connect/Add/Remove assertions");
// No server bytes arrive after Add. Closing must tear down that blocked live
// transport immediately, rather than waiting for a read timeout or worker.
$wp = port();
[$p, $pipes] = peer("blocked", $wp);
$live = new Client("http://127.0.0.1:$wp");
$sub = $live->subscribe("demo:state", ["room" => "blocked"]);
$start = microtime(true);
$sub->close();
$live->close();
ok(microtime(true) - $start < 0.25, "blocked read close bounded");
proc_close($p);
// The intentionally bounded queue keeps only the newest sixteen values.
$manager = new ReflectionClass(
    Convex\LiveManager::class,
)->newInstanceWithoutConstructor();
$s = new Subscription($manager, 99);
for ($i = 0; $i < 20; $i++) {
    $s->deliver(new Update($i));
}
for ($i = 4; $i < 20; $i++) {
    ok($s->nextUpdate(0.01)->value === $i, "newest-16 overflow");
}
echo "php socket fixtures passed\n";
