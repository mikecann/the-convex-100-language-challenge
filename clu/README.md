# CLU

CLU is a statically typed language created by Barbara Liskov and her group at
MIT in the 1970s. Its work on data abstraction, iterators, parameterised types,
and exception handling helped shape ideas that now feel ordinary in languages
such as C++ and ML. It is mainly of historical and research interest today,
but the community-maintained [Portable CLU project](https://hg.sr.ht/~nbuwe/pclu)
still makes the original language usable on modern systems. MIT's
[history of CLU](https://publications.csail.mit.edu/lcs/pubs/pdf/MIT-LCS-TR-561.pdf)
is the best primary account of why it was designed.

This client is an educational demonstration for a video and website. It is
unofficial, unsupported, and not a production Convex SDK.

## Getting Started

The [canonical example](examples/basics/main.clu) reads a fresh counter, starts
a Live subscription, increments the counter once, and receives the reactive
update. From the repository root, run it in its pinned Docker environment with:

```sh
./run verify-example clu
```

## Interesting Parts

### A cluster hides the representation

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "clu-cluster-readme" });
  return <p>{state?.count ?? "Loading..."}</p>; // state.count is type-safe here.
}
```

**CLU**

```clu
base_url: string := _environ("CONVEX_URL") % Real deployment configuration.
    except when not_found: signal failed("CONVEX_URL is required") end
if string$empty(base_url) then signal failed("CONVEX_URL is required") end
room: string := "clu-cluster-readme"
args_raw: string := json$object1("room", json$qs(room))

kind: string, value_raw: string, err_name: string, err_message: string,
    err_data: string, has_err_data: bool, logs_raw: string, has_logs: bool :=
    chttp$call("query", "demo:state", args_raw, base_url, "")

count_raw: string := json$field(value_raw, "count")
count: int := json$uint32(count_raw) % count is type-safe after explicit decoding.
```

The generated TypeScript API carries the function's argument and return types.
This small CLU client instead receives raw JSON and decodes the field it needs.
The React hook remains subscribed and rerenders on changes, while this focused
CLU call is only a one-off HTTP snapshot; the explicit Live lifecycle below is
the real reactive equivalent.
The interesting bit is the `$`: `json$uint32` and `chttp$call` invoke operations
exported by clusters. A cluster owns its hidden representation and exposes only
named operations, much like a class with private state, although a stateless
cluster such as `json` also works well as a module namespace.

### Live is an explicit, iterator-driven lifecycle

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const state = useQuery(api.demo.state, { room: "clu-live-readme" });
  return <p>{state?.count ?? "Loading..."}</p>; // React owns subscribe and cleanup.
}
```

**CLU**

```clu
base_url: string := _environ("CONVEX_URL") % Real deployment configuration.
    except when not_found: signal failed("CONVEX_URL is required") end
if string$empty(base_url) then signal failed("CONVEX_URL is required") end
room: string := "clu-live-readme"
args_raw: string := json$object1("room", json$qs(room))
s: sync := sync$create(base_url, "clu-0.1.0")
    except when not_possible (msg: string): signal failed(msg) end
query_id: int := sync$add(s, "demo:state", args_raw) % Start the subscription.

for attempt: int in int$from_to(1, 20) do % The iterator supplies loop values.
    found: bool, kind: string, ignored_id: int, value_raw: string,
        err_name: string, err_message: string, err_data: string,
        has_err_data: bool, has_logs: bool, logs_raw: string := sync$poll(s, 500)
        except when not_possible (msg: string): signal failed(msg) end
    if found cand string$equal(kind, "update") then
        count: int := json$uint32(json$field(value_raw, "count"))
        break % count is the latest reactive value, decoded as a CLU int.
        end
    end

sync$remove(s, query_id) % This command-line client owns unsubscribe and cleanup.
sync$close(s)
```

React's hook owns the subscription and rerenders the component when its value
changes. The CLU API deliberately exposes a blocking `poll` operation because
this Portable CLU runtime has no threads or async runtime. CLU's iterator drives
the bounded polling loop, while declared signals and nearby `except` clauses
make transport failures part of the control flow rather than magic return
values. The iterator does not make the subscription reactive by itself.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions against Convex's documented `"format":"json"` API | Verified by shared local and hosted conformance |
| RFC 6455 WebSocket framing (masking, fragmentation, interleaved control frames, UTF-8 validated once after reassembly) | Verified by shared local and hosted conformance |
| `/api/sync` Live: Add/Remove, initial and external `QueryUpdated`, `QueryFailed` and recovery, five real `debugDisconnect` reconnects with unchanged rehydration suppressed | Verified by shared local and hosted conformance |
| Conformance adapter (NDJSON v1, stdin/stdout and `ADAPTER_LISTEN` TCP) | Verified by shared local and hosted conformance |

`./run verify-all clu` passed 31/31 checks on both the local and hosted
profiles from a clean, exact-head commit; see `manifest.yaml`'s
`capabilities` list for the shared evaluator's own award.

## Example

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

## Implementation Notes

This is a native CLU implementation. HTTP framing, JSON scanning, WebSocket
framing, reconnect behaviour, and the Convex-specific work all live in the
checked-in `.clu` files. Portable CLU has raw sockets but no TLS API, so the
hosted path adds a small `_tls` builtin in C using OpenSSL. That builtin handles
DNS, TCP, certificate and hostname verification, and byte transport only. It
does not know anything about HTTP, WebSockets, JSON, or Convex.

The Live client is a `sync` cluster whose representation owns the connection,
subscription table, reconnect state, and a one-value delivery slot per active
query. With no runtime threads, both the example and test adapter advance that
state machine by calling `sync$poll`. A newer update replaces an undelivered
older one because a reactive query represents current state, not an event log.

The JSON layer is intentionally small. It walks enough structure to extract a
top-level field or array item as raw JSON, then callers decode only the values
they need. The example accepts Convex whole numbers written as `0`, `0.0`, or
`1.00`, while rejecting fractions, strings, non-finite values, and overflow.

The Docker gates are:

```sh
./run test clu
./run verify-example clu
./run verify clu
./run verify-hosted clu
./run verify-all clu
```

`test` builds pinned Portable CLU commit
`1a8ad7603ea20b9744942182a52810441182f6a6` and Boehm GC 8.2.8, checks source
style, runs the language-local tests, and compiles the example and adapter. GC
8.2.8 replaces pclu's documented 7.2f because that older release faults during
`GC_init` under Docker Desktop's amd64 Rosetta emulation. The remaining commands
run the canonical example and shared conformance against the local deployment,
hosted drift target, or both. Clean parent commit `305e9a4` passed all 31 local
and all 31 hosted checks from the same built image. This prose-only
reconciliation does not change those build inputs.

## Known Issues

1. Portable CLU has no threads or async runtime here, so callers must drive Live
   explicitly with bounded `sync$poll` calls.
2. The JSON codec is deliberately not a general JSON-to-CLU object mapper. New
   result shapes need explicit field extraction and decoding.
3. `TransitionChunk` is not implemented. The client reports it as a protocol
   error and reconnects instead of silently accepting a partial transition.
4. The build patches a Portable CLU 64-bit `_wordvec` addressing bug and uses a
   small CLU DNS resolver because pclu's bundled resolver misreads modern
   Docker-generated `resolv.conf` comments. These are runtime workarounds, not
   Convex protocol behaviour.
