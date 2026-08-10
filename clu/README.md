# Convex from CLU

This is a Convex client written in CLU, Barbara Liskov's 1975 language and
the original home of the abstract data type: every non-trivial piece of
state in this client (a `_tls` connection, the JSON scanner, the WebSocket
frame reader, the `/api/sync` state machine) is built as a CLU `cluster` --
data plus the operations on it, with no other code allowed to reach into its
representation -- which is precisely the idea CLU introduced.

## This is educational, not a production SDK

This client is a demonstration for a video and a website, not an official
Convex SDK. It is unofficial, unsupported, and not intended for production
use. CLU itself has been unmaintained since the early 1990s; this uses
[Portable CLU (pclu)](https://hg.sr.ht/~nbuwe/pclu), a 2021+ community
fix-up that builds on modern 64-bit Linux.

## Start here

The [canonical basic example](examples/basics/main.clu) queries a shared
counter over HTTP, starts a Live subscription before mutating it, applies the
mutation with an idempotency key, and proves the Live update agrees with the
mutation's own result -- the same `0 -> 1` journey every language in this
repository demonstrates.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions against Convex's documented `"format":"json"` API | Verified by shared local and hosted conformance |
| RFC 6455 WebSocket framing (masking, fragmentation, interleaved control frames, UTF-8 validated once after reassembly) | Verified by shared local and hosted conformance |
| `/api/sync` Live: Add/Remove, initial and external `QueryUpdated`, `QueryFailed` and recovery, five real `debugDisconnect` reconnects with unchanged rehydration suppressed | Verified by shared local and hosted conformance |
| Conformance adapter (NDJSON v1, stdin/stdout and `ADAPTER_LISTEN` TCP) | Verified by shared local and hosted conformance |

`./run verify-all clu` passed 31/31 checks on both the local and hosted
profiles from a clean, exact-head commit; see `manifest.yaml`'s
`capabilities` list for the shared evaluator's own award.

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.clu -->
```clu
%   main.clu -- the canonical Convex-from-CLU example: a shared counter
%   read over HTTP, watched over Live, and incremented once, proving
%   HTTP and Live agree on the same 0 -> 1 journey.
%
%   Every non-trivial piece of state this whole client touches --
%   json's own scanner, chttp's HTTP framing, sync's /api/sync state
%   machine -- is written as a CLU cluster: representation plus the
%   operations on it, with nothing outside the cluster able to reach
%   in and touch that representation directly. That is the idea CLU
%   (Barbara Liskov's language, and the original home of the abstract
%   data type) introduced, and this example leans on four such
%   clusters -- json, chttp, wsconn (through sync), and sync itself --
%   without this file ever seeing what is inside any of them. The
%   Live-update wait below also reaches for CLU's other distinctive
%   feature, the iterator: `for ... in int$from_to(...) do` is CLU's
%   own idiom for "keep asking a sequence for its next value until you
%   have what you need," which is exactly this example's own polling
%   loop.
%
%   stdout carries only the six lines a viewer of the website or video
%   is meant to see; every diagnostic (a missing CONVEX_URL, a failed
%   step) goes to stderr instead, and any unexpected value is a hard
%   failure, not a printed warning.

%   fail(operation, message) -> reports a failed step on stderr and
%   exits with a non-zero status. Never returns, so every call site
%   below can rely on whatever it was checking having held from that
%   point on.
fail = proc (operation, message: string)
    stream$putl(stream$error_output(), operation || ": " || message)
    _exit(1)
    end fail

%   check_result(operation, kind, err_name, err_message) -> fails unless
%   an chttp\$call's kind was "result" -- the same result/error shape
%   this client's own HTTP module classifies every Convex response into.
check_result = proc (operation, kind, err_name, err_message: string)
    if ~string$equal(kind, "result") then
	fail(operation, err_name || ": " || err_message)
	end
    end check_result

%   check_count(operation, value_raw, expected) -> decodes {"count": N}
%   from a raw Convex value (query result, mutation state, or Live
%   update) and fails unless N is exactly expected. json\$uint32 already
%   accepts Convex's integral-decimal spellings such as 0.0, so this
%   never has to special-case one itself.
check_count = proc (operation, value_raw: string, expected: int)
    count_raw: string := json$field(value_raw, "count")
	except when not_found, bad_format: fail(operation, "missing count")
	       end
    count: int := json$uint32(count_raw)
	except when bad_format:
		    fail(operation, "count is not a whole number")
	       end
    if count ~= expected then
	fail(operation, "count was " || int$unparse(count) || ", expected "
	     || int$unparse(expected))
	end
    end check_count

%   wait_for_value(s, timeout_ms) -> the JSON value text of the next
%   successfully delivered Live update on s, polling in half-second
%   slices (CLU's `for ... in int$from_to(...) do` iterator supplies
%   the "keep asking" loop; the deadline check inside is what actually
%   bounds it, since int\$from_to's own upper bound here is just a very
%   large safety cap). Signals failed(msg) if a QueryFailed error
%   arrives instead of a value, or if timeout_ms passes with nothing
%   delivered.
wait_for_value = proc (s: sync, timeout_ms: int) returns (string)
					       signals (failed(string))
    deadline: int := _real_time() + timeout_ms
    for attempt: int in int$from_to(1, 1000000) do
	if _real_time() >= deadline then
	    signal failed("timed out waiting for a Live update")
	    end
	found: bool, kind: string, query_id: int, value: string, ename: string,
	    emsg: string, edata: string, hed: bool, hlogs: bool,
	    logs: string := sync$poll(s, 500)
	    except when not_possible (msg: string): signal failed(msg) end
	if found then
	    if string$equal(kind, "error") then
		signal failed(ename || ": " || emsg)
		end
	    return(value)
	    end
	end
    signal failed("timed out waiting for a Live update")
    end wait_for_value

%   random_hex(n) -> n random bytes from /dev/urandom, hex encoded --
%   this example's own mutation idempotency key (runId). A fresh
%   mutation's idempotency key only has to be unique to this one run;
%   real entropy is what makes that true without any other
%   coordination, the same reason client/convex-websocket.clu's
%   handshake nonce and client/convex-sync.clu's session ID both read
%   from the same device rather than a seeded PRNG.
random_hex = proc (n: int) returns (string) signals (not_possible(string))
    fn: file_name := file_name$parse("/dev/urandom")
    ch: _chan := _chan$open(fn, "read", 0)
	except when not_possible (msg: string):
		    signal not_possible("open /dev/urandom: " || msg)
	       end
    rbytes: _bytevec := _bytevec$create(n)
    got: int := _chan$getb(ch, rbytes)
	except when not_possible (msg: string):
		    _chan$close(ch) except others: end
		    signal not_possible("read /dev/urandom: " || msg)
	       end
    _chan$close(ch) except others: end
    if got < n then signal not_possible("short read from /dev/urandom") end
    return(sha1$hex(_cvt[_bytevec, string](rbytes)))
    end random_hex

start_up = proc ()
    po: stream := stream$primary_output()
    eo: stream := stream$error_output()

    % -- configuration: the deployment URL always comes from the
    % environment, never hardcoded, so this same image can run against
    % any approved Convex deployment. This example calls only a public
    % demo function, so it never sets an auth token; a client that
    % needed one would pass it as chttp\$call's own token argument
    % instead of a header this file builds by hand.
    base_url: string := _environ("CONVEX_URL")
	except when not_found:
		    stream$putl(eo, "CONVEX_URL is required")
		    _exit(2)
	       end

    % The shared conformance harness passes a fresh, unique room as
    % this program's own first argument, so the counter demonstrated
    % below always starts at 0; running the image by hand without one
    % falls back to a fixed room name instead.
    args: sequence[string] := get_argv()
    room: string := "clu-basic-example"
    if sequence[string]$size(args) >= 1 then
	room := sequence[string]$fetch(args, 1)
	end
    query_args: string := json$object1("room", json$qs(room))

    % -- the HTTP query: a plain request/response round trip through
    % chttp (client/convex-http.clu), this client's own cluster for
    % Convex's documented "format":"json" /api/query endpoint.
    kind: string, value_raw: string, err_name: string, err_message: string,
	err_data: string, has_err_data: bool, logs_raw: string,
	has_logs: bool :=
	chttp$call("query", "demo:state", query_args, base_url, "")
    check_result("current query", kind, err_name, err_message)
    % Decoding {"count": N} into a plain CLU int is this step's "idiomatic
    % value": everything above this line is Convex protocol plumbing, and
    % everything below just works with an ordinary int.
    check_count("current query", value_raw, 0)
    stream$putl(po, "current count: 0")

    % -- start Live before the mutation. Subscribing to the same query
    % now and reading its first value before changing anything is what
    % makes the later "updated" value unambiguous: if the mutation ran
    % first, this client could never tell a genuinely new value apart
    % from one that was already current when the subscription began.
    s: sync := sync$create(base_url, "clu-0.1.0")
	except when not_possible (msg: string):
		    fail("create Live client", msg)
	       end
    query_id: int := sync$add(s, "demo:state", query_args)

    initial_value: string := wait_for_value(s, 10000)
	except when failed (msg: string): fail("initial Live value", msg) end
    check_count("initial Live value", initial_value, 0)
    stream$putl(po, "live initial count: 0")

    % -- the mutation, with its idempotency key. runId lets a retried
    % mutation (say, after a transient network failure between this
    % client and the deployment) return the already-applied result
    % instead of incrementing the counter a second time; a fresh random
    % one here only has to be unique to this one run.
    run_id: string := random_hex(8)
	except when not_possible (msg: string): fail("generate runId", msg) end
    mutation_args: string := json$object3("room", json$qs(room), "language",
					  json$qs("CLU"), "runId",
					  json$qs(run_id))
    mut_kind: string, mut_value: string, mut_err_name: string,
	mut_err_message: string, mut_err_data: string,
	mut_has_err_data: bool, mut_logs_raw: string,
	mut_has_logs: bool := chttp$call("mutation", "demo:increment",
					 mutation_args, base_url, "")
    check_result("mutation", mut_kind, mut_err_name, mut_err_message)
    applied_raw: string := json$field(mut_value, "applied")
	except when not_found, bad_format:
		    fail("mutation", "missing applied")
	       end
    if ~string$equal(applied_raw, "true") then
	fail("mutation", "was not applied")
	end
    stream$putl(po, "mutation applied: true")
    mutation_state: string := json$field(mut_value, "state")
	except when not_found, bad_format: fail("mutation", "missing state")
	       end
    check_count("mutation", mutation_state, 1)
    stream$putl(po, "mutation count: 1")

    % -- the resulting Live update, received without issuing a second
    % HTTP query: this is Convex's own reactivity working end to end,
    % over the /api/sync WebSocket state machine client/convex-sync.clu
    % implements.
    updated_value: string := wait_for_value(s, 10000)
	except when failed (msg: string): fail("updated Live value", msg) end
    check_count("updated Live value", updated_value, 1)
    stream$putl(po, "live updated count: 1")

    % -- cleanup: stop the subscription and close the Live connection
    % before printing the final line, so a hang during teardown would
    % itself be a visible example failure rather than a silently
    % skipped step.
    sync$remove(s, query_id) except when not_possible (ignored: string): end
    sync$close(s) except when not_possible (ignored: string): end

    % Reached only once the HTTP query, the initial Live value, the
    % mutation, and the updated Live value all agree on the same
    % 0 -> 1 journey.
    stream$putl(po, "verified count: 0 -> 1")
    end start_up
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test clu
```

Builds pclu 1a8ad7603ea20b9744942182a52810441182f6a6 from source (Boehm GC
8.2.8 static, replacing the 2014 GC 7.2f release that faults during `GC_init`
under Docker Desktop's amd64 Rosetta emulation, and
`client/wordvec-64bit-word-size.patch`, a real 64-bit addressing bug fixed
during development), adds the `_tls` builtin cluster, boots a hello-world
smoke test, checks source style, compiles and runs the full language-local
unit suite (JSON codec, arithmetic bitwise helpers, base64, this client's own
DNS resolver, HTTP/1.1 framing, RFC 6455 WebSocket framing, and the
`/api/sync` state machine -- the last four against real loopback-TCP peers,
not mocks), compiles and links the canonical example and the conformance
adapter, and proves the adapter's own hello/close NDJSON lifecycle.

```sh
./run verify-example clu
./run verify clu
./run verify-hosted clu
./run verify-all clu
```

Run the canonical example and the shared black-box conformance suite against
the local backend, the hosted drift target, and both together, respectively.

## Lower-level notes

- **pclu's C-boundary mechanism.** A `.spc` file declares a cluster's
  operation signatures with empty bodies (interface only, never compiled to a
  body); a separate hand-authored `.c` file supplies C functions named
  `<type>OP<opname>` that the linker resolves by that naming convention when
  `libpclu_opt.a` is linked. No dlopen, no FFI declarations, no glue-code
  generator. pclu's own builtins (`_chan`, `_wordvec`, ...) are written this
  way; `client/convexrt-tls.c` + `client/_tls.spc` add one more, the same
  way. `_tls$recv` takes an explicit `timeout_ms` and waits with `poll(2)` on
  the connection's own file descriptor before ever calling `SSL_read`, so a
  caller can tell a live-but-idle connection (signals `timeout`) apart from
  one the peer actually closed (signals `end_of_file`).
- **The 64-bit `_wordvec` bug.** `client/wordvec-64bit-word-size.patch`
  fixes a real, previously unreported bug: on 64-bit builds `_wordvec`'s
  byte- and half-word-addressed operations could only ever address the first
  four bytes of every eight-byte storage slot. See the patch file's own
  header comment for the full write-up; it is likely worth reporting to
  upstream pclu independently of this project.
- **pclu's own bundled DNS client silently fails against Docker's
  resolv.conf.** `lib/clu/_resolve.clu` only recognises `;` as a comment
  character (an Ultrix/BSD convention from its 1985/1989 MIT copyright
  header); every modern Linux resolv.conf, including the one Docker
  generates, uses `#` instead. `_resolve` mistakes the first comment line
  for the domain/nameserver line it expects, fails to parse it as an
  address, silently swallows that failure, and is left querying the
  untouched default of `127.0.0.1` until every real hostname lookup times
  out. Rather than patch unfamiliar 1980s DNS wire-format C, this client
  ships its own small resolver, `client/convex-dns.clu`: it reads the real
  nameserver out of `/etc/resolv.conf` correctly, sends one A-record query
  over UDP, and parses the answer (including DNS name compression
  pointers). `convex-transport.clu`'s `dial()` calls it exactly where it
  used to call `_resolve$n2a`, with the same three signals.
- **Local vs. hosted transport.** `client/convex-transport.clu`'s `conn`
  type is a `oneof[chan: _chan, tls: _tls]`: the local profile dials a raw
  `_chan` socket by hand (a literal dotted-quad address via `inet_address`,
  or `client/convex-dns.clu` if that fails); the hosted profile calls
  `_tls$connect`, which does DNS (via OpenSSL/glibc, not this client's own
  resolver), the TCP connect, and the TLS handshake (with real chain and
  hostname verification) all inside one C builtin.
- **`convex-sync.clu` has no owner thread, because pclu has no threads.**
  Instead the whole `/api/sync` state machine lives behind one `poll()`
  operation that does at most one bounded WebSocket read per call and
  returns at most one delivery; a caller (the conformance adapter, or the
  canonical example) drives it by calling `poll()` repeatedly. See
  `convex-sync.clu`'s own header comment for the full reasoning, including
  why this client's delivery buffering is deliberately one slot per
  subscription rather than a queue.
- **The conformance adapter is the same kind of loop.** It reads one
  buffered NDJSON command line if one is ready; otherwise it waits briefly
  for more input; if nothing arrived, it gives `sync$poll()` one chance to
  check the Live socket and deliver at most one subscription event. Every
  event is written the moment it is produced, never batched, which is this
  client's whole answer to a stopped reader: ordinary pipe backpressure
  stalls this same loop rather than it ever accumulating a backlog of its
  own.
- **Several real pclu quirks were found and are documented at their call
  sites** (`convex-http.clu`, `convex-websocket.clu`, `convex-sync.clu`,
  `convex-dns.clu`, the conformance adapter): a `return` statement's
  expression list is positional, one value per slot; an `except` clause
  binds only to the single statement immediately before it; identifiers are
  resolved case-insensitively, so words like `any` and `has` that appear
  inside pclu's own generic-type/where-clause syntax collide with an
  ordinary local variable of the same name; a `cvt`-typed operation
  parameter is already treated as `rep` inside its own operation, so
  passing it on as another `cvt`-taking operation's own argument needs an
  explicit `up()` conversion; and `_chan$recv`/`$send` only work on an
  actual socket (`_chan$getb`/`$putb`, plain `read(2)`/`write(2)`, work on
  a pipe, a character device, or a socket alike).

## Known limitations

See `manifest.yaml`'s `limitations` list, which is the source of truth and
is kept current as this client progresses.
