<?php
declare(strict_types=1);

/* Native, dependency-free Convex experiment.  HTTP is documented; the small
 * RFC6455 transport below is deliberately kept separate from the pinned sync
 * state machine so readers can see which part is protocol-specific. */
namespace Convex;

class Error extends \RuntimeException {}
class ProtocolError extends Error {}
class ClosedError extends Error {}
class TransportError extends Error
{
    public function __construct(
        string $m,
        public string $operation = "transport",
    ) {
        parent::__construct("Convex $operation transport error: $m");
    }
}
class FunctionError extends Error
{
    public function __construct(
        string $m,
        public string $operation,
        public mixed $data = null,
        public array $logs = [],
    ) {
        parent::__construct("Convex $operation failed: $m");
    }
}
final class Result
{
    public function __construct(public mixed $value, public array $logs = []) {}
}
final class Update
{
    public function __construct(
        public mixed $value = null,
        public ?Error $error = null,
        public array $logs = [],
    ) {}
}

final class Client
{
    private string $url;
    private string $token = "";
    private bool $closed = false;
    private ?LiveManager $live = null;
    public function __construct(
        string $url,
        ?string $bearerToken = null,
        private string $version = "php-0.1.0",
    ) {
        $p = parse_url($url);
        if (
            !is_array($p) ||
            !isset($p["scheme"], $p["host"]) ||
            !in_array($p["scheme"], ["http", "https"], true) ||
            isset($p["user"])
        ) {
            throw new \InvalidArgumentException(
                "Convex deployment URL must be http(s) with a host",
            );
        }
        $this->url = rtrim($url, "/");
        $this->token = (string) $bearerToken;
    }
    public function setAuth(string $token): void
    {
        $this->guard();
        $this->token = $token;
    }
    public function query(string $path, array $args = []): Result
    {
        return $this->call("query", $path, $args);
    }
    public function mutation(string $path, array $args = []): Result
    {
        return $this->call("mutation", $path, $args);
    }
    public function action(string $path, array $args = []): Result
    {
        return $this->call("action", $path, $args);
    }
    public function subscribe(string $path, array $args = []): Subscription
    {
        $this->validate($path, $args);
        $this->guard();
        return ($this->live ??= new LiveManager(
            $this->url,
            $this->version,
        ))->subscribe($path, $args);
    }
    public function pump(float $timeout = 0.0): void
    {
        $this->live?->pump($timeout);
    }
    public function debugDisconnectForAdapter(): void
    {
        $this->guard();
        if (!$this->live) {
            throw new TransportError("Live WebSocket is not connected", "live");
        }
        $this->live->debugDisconnect();
    }
    public function close(): void
    {
        if (!$this->closed) {
            $this->closed = true;
            $this->live?->close();
        }
    }
    private function guard(): void
    {
        if ($this->closed) {
            throw new ClosedError("Convex client is closed");
        }
    }
    private function validate(string $path, array $args): void
    {
        if ($path === "") {
            throw new \InvalidArgumentException(
                "Convex function path is required",
            );
        }
        try {
            json_encode(
                $args,
                JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE,
            );
        } catch (\JsonException $e) {
            throw new \InvalidArgumentException(
                "encode Convex arguments: " . $e->getMessage(),
            );
        }
    }
    private function call(string $op, string $path, array $args): Result
    {
        $this->guard();
        $this->validate($path, $args);
        $body = json_encode(
            ["path" => $path, "args" => $args, "format" => "json"],
            JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE,
        );
        $headers =
            "Content-Type: application/json\r\nAccept: application/json\r\nConvex-Client: {$this->version}\r\n" .
            ($this->token === ""
                ? ""
                : "Authorization: Bearer {$this->token}\r\n");
        $ctx = stream_context_create([
            "http" => [
                "method" => "POST",
                "header" => $headers,
                "content" => $body,
                "timeout" => 30,
                "ignore_errors" => true,
            ],
        ]);
        $raw = @file_get_contents("{$this->url}/api/$op", false, $ctx);
        if ($raw === false) {
            throw new TransportError(
                error_get_last()["message"] ?? "HTTP request failed",
                $op,
            );
        }
        if (strlen($raw) > 2097152) {
            throw new TransportError("response exceeds 2097152 bytes", $op);
        }
        try {
            $decoded = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new TransportError(
                "HTTP response was not JSON: " . $e->getMessage(),
                $op,
            );
        }
        if (
            ($decoded["status"] ?? null) === "success" &&
            array_key_exists("value", $decoded)
        ) {
            return new Result(
                $decoded["value"],
                array_values($decoded["logLines"] ?? []),
            );
        }
        if (($decoded["status"] ?? null) === "error") {
            throw new FunctionError(
                (string) ($decoded["errorMessage"] ?? ""),
                $op,
                $decoded["errorData"] ?? null,
                array_values($decoded["logLines"] ?? []),
            );
        }
        throw new ProtocolError("HTTP response has unknown Convex status");
    }
}

final class Subscription
{
    /** newest sixteen wins: slow consumers retain the latest reactive state. */
    private array $updates = [];
    private bool $finished = false;
    public function __construct(private LiveManager $manager, public int $id) {}
    public function nextUpdate(float $timeout = 10): Update
    {
        $end = microtime(true) + $timeout;
        while (!$this->updates && !$this->finished) {
            $this->manager->pump(max(0.0, min(0.1, $end - microtime(true))));
            if (microtime(true) >= $end) {
                throw new TransportError(
                    "timed out waiting for Live update",
                    "live",
                );
            }
        }
        if (!$this->updates) {
            throw new ClosedError("Live subscription is closed");
        }
        return array_shift($this->updates);
    }
    public function deliver(Update $u): void
    {
        if (!$this->finished) {
            if (count($this->updates) === 16) {
                array_shift($this->updates);
            }
            $this->updates[] = $u;
        }
    }
    public function close(): void
    {
        if (!$this->finished) {
            $this->manager->unsubscribe($this->id);
        }
    }
    public function finish(): void
    {
        $this->finished = true;
        $this->updates = [];
    }
}

final class LiveManager
{
    private ?WebSocket $ws = null;
    private array $subs = [];
    private int $next = 0,
        $querySet = 0,
        $connections = 0;
    private array $remote = [
        "querySet" => 0,
        "identity" => 0,
        "ts" => "AAAAAAAAAAA=",
    ];
    private float $reconnectAt = 0,
        $backoff = 0.1;
    private string $lastClose = "InitialConnect";
    private bool $closed = false;
    public function __construct(private string $url, private string $version) {}
    public function subscribe(string $path, array $args): Subscription
    {
        if ($this->closed) {
            throw new ClosedError("Live manager is closed");
        }
        $s = new Subscription($this, $this->next++);
        $this->subs[$s->id] = [
            "path" => $path,
            "args" => $args,
            "subscription" => $s,
        ];
        $this->ensure();
        if ($this->ws) {
            $this->modify([self::add($s->id, $this->subs[$s->id])]);
        }
        return $s;
    }
    public function unsubscribe(int $id): void
    {
        $state = $this->subs[$id] ?? null;
        unset($this->subs[$id]);
        if ($state) {
            $state["subscription"]->finish();
            if ($this->ws) {
                $this->modify([["type" => "Remove", "queryId" => $id]]);
            }
        }
    }
    public function debugDisconnect(): void
    {
        if (!$this->ws) {
            $this->ensure();
            if (!$this->ws) {
                throw new TransportError(
                    "Live WebSocket is not connected",
                    "live",
                );
            }
        }
        // Adapter-only: confirm the old transport is closed, then return so the
        // adapter can acknowledge before an external mutation is made. The normal
        // 100 ms reconnect path will resubscribe and observe that newer value.
        $this->disconnect("DebugDisconnect");
    }
    public function close(): void
    {
        $this->closed = true;
        $this->ws?->close();
        $this->ws = null;
        foreach ($this->subs as $s) {
            $s["subscription"]->finish();
        }
        $this->subs = [];
    }
    public function pump(float $timeout = 0): void
    {
        if ($this->closed) {
            return;
        }
        $this->ensure();
        if (!$this->ws) {
            if ($timeout > 0) {
                usleep((int) ($timeout * 1000000));
            }
            return;
        }
        $this->ws->wait($timeout);
        while (($raw = $this->ws->read()) !== false) {
            if ($raw === null) {
                $this->disconnect("ServerClosed");
                break;
            }
            $this->handle($raw);
        }
    }
    private function ensure(): void
    {
        if ($this->ws || !$this->subs || microtime(true) < $this->reconnectAt) {
            return;
        }
        try {
            $p = parse_url($this->url);
            $scheme = $p["scheme"] === "https" ? "wss" : "ws";
            $host = $p["host"];
            $port = isset($p["port"]) ? ":" . $p["port"] : "";
            $path = rtrim($p["path"] ?? "", "/") . "/api/sync";
            $this->ws = new WebSocket(
                "$scheme://$host$port$path",
                $this->version,
            );
            $this->querySet = 0;
            $this->remote = [
                "querySet" => 0,
                "identity" => 0,
                "ts" => "AAAAAAAAAAA=",
            ];
            $this->ws->send([
                "type" => "Connect",
                "sessionId" => self::uuid(),
                "connectionCount" => $this->connections,
                "lastCloseReason" => $this->lastClose,
                "clientTs" => 0,
            ]);
            $mods = [];
            foreach ($this->subs as $id => $s) {
                $mods[] = self::add($id, $s);
            }
            if ($mods) {
                $this->modify($mods);
            }
            $this->backoff = 0.1;
        } catch (\Throwable $e) {
            $this->disconnect($e->getMessage());
        }
    }
    private function modify(array $mods): void
    {
        if (!$this->ws) {
            return;
        }
        $this->ws->send([
            "type" => "ModifyQuerySet",
            "baseVersion" => $this->querySet,
            "newVersion" => $this->querySet + 1,
            "modifications" => $mods,
        ]);
        $this->querySet++;
    }
    private static function add(int $id, array $s): array
    {
        return [
            "type" => "Add",
            "queryId" => $id,
            "udfPath" => $s["path"],
            "args" => [$s["args"]],
        ];
    }
    private function handle(string $raw): void
    {
        try {
            $m = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new ProtocolError(
                "decode server message: " . $e->getMessage(),
            );
        }
        if (($m["type"] ?? "") !== "Transition") {
            if (
                in_array(
                    $m["type"] ?? "",
                    ["Ping", "MutationResponse", "ActionResponse"],
                    true,
                )
            ) {
                return;
            }
            throw new ProtocolError(
                "unknown server message " . ($m["type"] ?? ""),
            );
        }
        if (($m["startVersion"] ?? null) != $this->remote) {
            throw new ProtocolError("Transition start version mismatch");
        }
        $changed = [];
        foreach ($m["modifications"] ?? [] as $x) {
            $id = $x["queryId"];
            if (($x["type"] ?? "") === "QueryUpdated") {
                $changed[$id] = new Update(
                    $x["value"] ?? null,
                    null,
                    array_values($x["logLines"] ?? []),
                );
            } elseif (($x["type"] ?? "") === "QueryFailed") {
                $changed[$id] = new Update(
                    null,
                    new FunctionError(
                        (string) ($x["errorMessage"] ?? ""),
                        "query",
                        $x["errorData"] ?? null,
                        array_values($x["logLines"] ?? []),
                    ),
                    array_values($x["logLines"] ?? []),
                );
            }
        }
        $this->remote = $m["endVersion"];
        foreach ($changed as $id => $u) {
            if (isset($this->subs[$id])) {
                $this->subs[$id]["subscription"]->deliver($u);
            }
        }
    }
    private function disconnect(string $reason): void
    {
        $this->ws?->close();
        $this->ws = null;
        $this->connections++;
        $this->lastClose = $reason;
        $this->querySet = 0;
        $this->remote = [
            "querySet" => 0,
            "identity" => 0,
            "ts" => "AAAAAAAAAAA=",
        ];
        $this->reconnectAt = microtime(true) + $this->backoff;
        $this->backoff = min(15, $this->backoff * 2);
    }
    private static function uuid(): string
    {
        $b = random_bytes(16);
        $b[6] = chr((ord($b[6]) & 15) | 64);
        $b[8] = chr((ord($b[8]) & 63) | 128);
        return vsprintf("%s%s-%s-%s-%s-%s%s%s", str_split(bin2hex($b), 4));
    }
}

final class WebSocket
{
    private $io;
    private string $buffer = "";
    private string $fragments = "";
    private ?int $fragmentOpcode = null;
    public function __construct(string $url, string $version)
    {
        $p = parse_url($url);
        $ssl = $p["scheme"] === "wss";
        $target =
            ($ssl ? "ssl" : "tcp") .
            "://" .
            $p["host"] .
            ":" .
            ($p["port"] ?? ($ssl ? 443 : 80));
        $this->io = @stream_socket_client(
            $target,
            $e,
            $s,
            10,
            STREAM_CLIENT_CONNECT,
            stream_context_create([
                "ssl" => ["verify_peer" => true, "peer_name" => $p["host"]],
            ]),
        );
        if (!$this->io) {
            throw new TransportError("WebSocket connect: $s", "live");
        }
        stream_set_blocking($this->io, true);
        $key = base64_encode(random_bytes(16));
        $resource =
            ($p["path"] ?? "/") . (isset($p["query"]) ? "?" . $p["query"] : "");
        fwrite(
            $this->io,
            "GET $resource HTTP/1.1\r\nHost: {$p["host"]}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nConvex-Client: $version\r\n\r\n",
        );
        $h = "";
        while (!str_contains($h, "\r\n\r\n")) {
            $c = fread($this->io, 1);
            if ($c === "" || $c === false) {
                throw new ProtocolError("WebSocket upgrade closed");
            }
            $h .= $c;
            if (strlen($h) > 32768) {
                throw new ProtocolError("WebSocket headers too large");
            }
        }
        $lines = explode("\r\n", $h);
        if (!str_contains($lines[0], " 101 ")) {
            throw new ProtocolError("WebSocket upgrade failed");
        }
        $headers = [];
        foreach ($lines as $l) {
            if (str_contains($l, ":")) {
                [$a, $b] = explode(":", $l, 2);
                $headers[strtolower($a)] = trim($b);
            }
        }
        if (
            ($headers["sec-websocket-accept"] ?? "") !==
            base64_encode(
                sha1($key . "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", true),
            )
        ) {
            throw new ProtocolError("invalid WebSocket accept");
        }
        stream_set_blocking($this->io, false);
    }
    public function wait(float $seconds): void
    {
        $r = [$this->io];
        $w = $e = [];
        @stream_select(
            $r,
            $w,
            $e,
            (int) $seconds,
            (int) (($seconds - (int) $seconds) * 1000000),
        );
    }
    public function send(array $v): void
    {
        $this->frame(
            1,
            json_encode($v, JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE),
        );
    }
    public function read(): string|false|null
    {
        $chunk = stream_get_contents($this->io);
        $this->buffer .= $chunk ?: "";
        if ($this->buffer === "" && feof($this->io)) {
            return null;
        }
        while (true) {
            if (strlen($this->buffer) < 2) {
                return false;
            }
            [$a, $b] = array_values(unpack("C2", substr($this->buffer, 0, 2)));
            $fin = (bool) ($a & 128);
            $len = $b & 127;
            $at = 2;
            if ($b & 128) {
                throw new ProtocolError(
                    "server WebSocket frames must not be masked",
                );
            }
            if ($len === 126) {
                if (strlen($this->buffer) < 4) {
                    return false;
                }
                $len = unpack("n", substr($this->buffer, 2, 2))[1];
                $at = 4;
            } elseif ($len === 127) {
                throw new ProtocolError("oversized WebSocket frame");
            }
            if ($len > 2097152) {
                throw new ProtocolError("WebSocket frame too large");
            }
            if (strlen($this->buffer) < $at + $len) {
                return false;
            }
            $payload = substr($this->buffer, $at, $len);
            $this->buffer = substr($this->buffer, $at + $len);
            $op = $a & 15;
            if ($op === 8) {
                return null;
            }
            if ($op === 9) {
                $this->frame(10, $payload);
                continue;
            }
            if ($op === 10) {
                continue;
            }
            if ($op === 1) {
                if ($this->fragmentOpcode !== null) {
                    throw new ProtocolError("interleaved WebSocket text");
                }
                $this->fragments = $payload;
                $this->fragmentOpcode = 1;
            } elseif ($op === 0) {
                if ($this->fragmentOpcode === null) {
                    throw new ProtocolError(
                        "unexpected WebSocket continuation",
                    );
                }
                $this->fragments .= $payload;
            } else {
                throw new ProtocolError("unsupported WebSocket frame");
            }
            if (strlen($this->fragments) > 2097152) {
                throw new ProtocolError("WebSocket message too large");
            }
            if (!$fin) {
                continue;
            }
            $message = $this->fragments;
            $this->fragments = "";
            $this->fragmentOpcode = null;
            return $message;
        }
    }
    private function frame(int $op, string $payload): void
    {
        $n = strlen($payload);
        $mask = random_bytes(4);
        $head =
            chr(128 | $op) .
            ($n < 126 ? chr(128 | $n) : chr(254) . pack("n", $n));
        $out = "";
        for ($i = 0; $i < $n; $i++) {
            $out .= $payload[$i] ^ $mask[$i % 4];
        }
        fwrite($this->io, $head . $mask . $out);
    }
    public function close(): void
    {
        if (is_resource($this->io)) {
            fclose($this->io);
        }
    }
}
