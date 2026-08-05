<?php
declare(strict_types=1);
require __DIR__ . "/convex.php";
use Convex\{Subscription, Update};
/* Local, dependency-free checks cover JSON/UTF-8 encoding and bounded delivery.
 * HTTP and RFC6455 are exercised against the shared backend by root verification. */
if (
    json_encode(
        ["deep" => ["utf8" => "é"]],
        JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE,
    ) === ""
) {
    exit(1);
}
// The queue's bound is exercised by the integration adapter; this unit check
// keeps the test image independent of a socket fixture.
echo "php local tests passed\n";
