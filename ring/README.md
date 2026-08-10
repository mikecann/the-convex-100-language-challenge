<img src="logo.png" alt="Ring logo" width="220">
<!-- Logo source: https://ring-lang.github.io/images/theringlogo.jpg -->

# Ring

[Ring](https://ring-lang.github.io/) is a dynamic, multi-paradigm language for
building applications, tools, and domain-specific languages. [Mahmoud Fayed's
earlier Supernova GUI language inspired the design, and work on Ring began in
2011](https://ring-lang.github.io/doc1.27/introduction.html). The project
released Ring 1.0 in 2016. Ring compiles to bytecode for its own
virtual machine, whose implementation is written in ANSI C, and its influences
include C, C++, C#, Lua, Python, Ruby, BASIC, and Supernova.

The project targets console programs, desktop and mobile GUIs, web apps, games,
embedded systems, and languages tailored to a particular problem. Ring remains
a niche choice beside mainstream application languages, but it is actively
maintained: [Ring 1.27 was released in May
2026](https://ring-lang.github.io/news.html), alongside an active collection of
libraries and applications.

This repository's client is an educational, unofficial experiment. It is not a
production SDK, an officially sanctioned Convex client, or a package intended
for publication.

## Getting Started

Start with [`examples/basics/main.ring`](examples/basics/main.ring). It queries
a fresh counter, subscribes before changing it, applies an idempotent mutation,
and observes the reactive update from `0` to `1`.

From the repository root, run the canonical program in its Docker image:

```sh
./run verify-example ring
```

That command builds the example runtime, gives the program a unique counter
room, and checks its output against the repository's shared expected transcript.
You do not need Ring installed on your host.

## Interesting Parts

### Convex values stay as exact JSON until Ring asks for a field

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={async () => {
        const result = await increment({
          room: "readme-ring",
          language: "TypeScript",
          runId: crypto.randomUUID(), // Fresh idempotency key for this button action.
        });
        console.log(result.state.count); // The generated API makes count a number.
      }}
    >
      Increment
    </button>
  );
}
```

**Ring**

```text
load "convex.ring"

cDeployment = cvxEnv("CONVEX_URL")
oConvex = new ConvexClient(cDeployment) # Reuses one TLS-verified HTTP handle.

# Ring builds the argument object as JSON text, including a unique idempotency key.
cArgs = cvxJsonObject([
	["room", cvxJsonQuote("readme-ring")],
	["language", cvxJsonQuote("Ring")],
	["runId", cvxJsonQuote(lower(hex(floor(uv_hrtime() / 1000))))]])

aResult = oConvex.mutation("demo:increment", cArgs) # A blocking HTTP call.
cState = cvxJsonField(aResult[:value], "state", true)
nCount = cvxWholeNumber(cvxJsonField(cState, "count", true), "mutation count")
? nCount # The helper rejects fractions, strings, and overflowing values.

oConvex.close() # Releases the reusable HTTP handle.
```

The React client returns a generated, type-safe object. This Ring client instead
retains Convex values as byte-exact JSON text, then validates only the fields the
program uses. That is a client design suited to Ring's dynamic type system, not
a requirement of the language.

### A Live subscription is an event loop you can see

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function Counter() {
  const room = "readme-ring";
  const state = useQuery(api.demo.state, { room });

  // Convex owns the subscription and React rerenders when state changes.
  return <output>{state === undefined ? "Loading" : state.count}</output>;
}
```

**Ring**

```text
load "convex.ring"

cDeployment = cvxEnv("CONVEX_URL")
oConvex = new ConvexClient(cDeployment)
cArgs = cvxJsonObject([["room", cvxJsonQuote("readme-ring")]])
nSubscription = oConvex.subscribe("demo:state", cArgs) # Opens Live on demand.

nDeadline = cvxNowMs() + 20000
while cvxNowMs() < nDeadline
	oConvex.pump(200)        # Give the client time to receive or reconnect.
	aEvent = oConvex.nextEvent() # Take the oldest buffered delivery.
	if len(aEvent) = 0 or aEvent[1] != nSubscription
		loop
	ok
	if aEvent[2] = "error"
		raise(aEvent[6]) # A reactive function or transport failure is explicit.
	ok
	nCount = cvxWholeNumber(cvxJsonField(aEvent[3], "count", true), "live count")
	? nCount
	exit
end

oConvex.unsubscribe(nSubscription) # Stop this reactive query first.
oConvex.close()                     # Then release HTTP and WebSocket handles.
```

`useQuery` hides subscription setup, cleanup, and rerender scheduling inside
React. The Ring client deliberately exposes `pump()` and an explicit
`nextEvent()` queue so a command-line program decides when network work runs.
Ring supports other programming styles; this explicit lifecycle is this
client's API choice.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Query, mutation, action, bearer-token lifecycle, log lines, and structured function errors work over TLS-verified HTTP. |
| Live | Verified by shared local and hosted conformance | Subscriptions, external updates, structured failures, bounded buffering, unsubscribe barriers, and reconnect recovery work over a real WebSocket. |

Root-owned local and hosted black-box conformance passed 31/31 from clean,
exact-head builds. The evaluator awarded both `http` and `live`, and the
manifest records those capabilities. This README-only change did not rerun
Docker or shared conformance.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ring -->
```text
#!/opt/ring/bin/ring
# The canonical Convex-from-Ring example. It uses exactly the same client
# source as the conformance adapter, so this file is what the README shows and
# what Docker actually runs.
load "convex.ring"

# Wait for the next Live delivery on one subscription. Convex updates arrive on
# a socket the client owns, so the example pumps that socket in short slices
# rather than blocking forever, and it treats a reactive failure as a real
# failure instead of quietly retrying.
func exampleNextValue oConvex, nQueryId, cStage
	nDeadlineMs = 20000
	nStarted = cvxNowMs()
	while cvxNowMs() - nStarted < nDeadlineMs
		oConvex.pump(200)
		aEvent = oConvex.nextEvent()
		if len(aEvent) = 0
			loop
		ok
		if aEvent[1] != nQueryId
			loop
		ok
		if aEvent[2] = "error"
			raise("the " + cStage + " Live update failed: " + aEvent[6])
		ok
		return aEvent[3]
	end
	raise("the " + cStage + " Live update did not arrive")

# Convex sends the counter as JSON, where a whole number may be spelled 0 or
# 0.0. cvxWholeNumber accepts that mathematical integer and rejects fractions,
# quoted numbers and anything that would overflow, so an unexpected shape fails
# the example instead of being rounded into a plausible answer.
func exampleCount cRaw, cStage
	return cvxWholeNumber(cvxJsonField(cRaw, "count", true), cStage + " count")

func main
	# Configuration comes from the environment, and the room comes from the
	# first argument so every verification run gets a private counter.
	cDeployment = cvxEnv("CONVEX_URL")
	if cDeployment = ""
		raise("CONVEX_URL is required")
	ok
	cRoom = "ring-example"
	if len(sysargv) >= 3 and sysargv[3] != ""
		cRoom = sysargv[3]
	ok

	# Creating the client only records the deployment. No socket is opened until
	# a subscription needs one.
	oConvex = new ConvexClient(cDeployment)
	cRoomArgs = cvxJsonObject([["room", cvxJsonQuote(cRoom)]])
	nSubscription = -1

	try
		# Ask Convex once over HTTP. This establishes that the room really is
		# fresh before anything reactive is involved.
		aCurrent = oConvex.query("demo:state", cRoomArgs)
		nCurrent = exampleCount(aCurrent[:value], "the current query")
		if nCurrent != 0
			raise("the current count was " + cvxIntText(nCurrent) + ", expected 0")
		ok
		? "current count: " + cvxIntText(nCurrent)

		# Start Live before changing anything. Its first value proves that no
		# mutation slipped in between the query above and the write below.
		nSubscription = oConvex.subscribe("demo:state", cRoomArgs)
		nInitial = exampleCount(exampleNextValue(oConvex, nSubscription, "initial"),
			"the initial Live value")
		if nInitial != nCurrent
			raise("the initial Live count disagreed with HTTP")
		ok
		? "live initial count: " + cvxIntText(nInitial)

		# runId is the mutation's idempotency key. Convex records it, so
		# retrying this logical request could never double-increment the room.
		cRunId = lower(hex(floor(uv_hrtime() / 1000)))
		aMutation = oConvex.mutation("demo:increment", cvxJsonObject([
			["room", cvxJsonQuote(cRoom)],
			["language", cvxJsonQuote("Ring")],
			["runId", cvxJsonQuote(cRunId)]]))
		if cvxJsonField(aMutation[:value], "applied", true) != "true"
			raise("the mutation was not applied")
		ok
		? "mutation applied: true"
		nMutation = exampleCount(cvxJsonField(aMutation[:value], "state", true), "the mutation")
		if nMutation != 1
			raise("the mutation count was " + cvxIntText(nMutation) + ", expected 1")
		ok
		? "mutation count: " + cvxIntText(nMutation)

		# Take the changed value from the subscription rather than issuing
		# another query. Anything the server sent while the mutation was in
		# flight is already buffered, so there is no race to arm against.
		nUpdated = exampleCount(exampleNextValue(oConvex, nSubscription, "updated"),
			"the updated Live value")
		if nUpdated != 1
			raise("the updated Live count was " + cvxIntText(nUpdated) + ", expected 1")
		ok
		? "live updated count: " + cvxIntText(nUpdated)
		? "verified count: 0 -> 1"
	catch
		# Always release the subscription and the sockets, then let the failure
		# reach the caller so a wrong value can never look like a pass.
		exampleCleanup(oConvex, nSubscription)
		raise(cCatchError)
	done
	exampleCleanup(oConvex, nSubscription)

# Removing the subscription first tells Convex to stop the reactive query;
# closing the client then releases the WebSocket and the HTTP connection.
func exampleCleanup oConvex, nSubscription
	if nSubscription >= 0
		oConvex.unsubscribe(nSubscription)
	ok
	oConvex.close()
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native Ring implementation. RingLibCurl provides TLS, HTTP, and RFC
6455 WebSocket framing, while RingLibuv provides the monotonic clock and the
test adapter's controller stream. Request envelopes, response classification,
JSON scanning, Live query state, reconnects, and publication decisions are all
implemented in [`client/convex.ring`](client/convex.ring), without delegating to
another Convex client.

Ring has numbers, strings, lists, and objects rather than a TypeScript-style
generated model for each Convex function. The client therefore keeps returned
Convex values as exact JSON subtrees. Helper functions quote strings, select
object fields, and accept integral JSON numbers such as `1.0` while rejecting a
fractional or quoted count. Result records are Ring lists with string keys, so
`aResult[:value]` selects the raw successful value.

Live delivery uses a client-owned FIFO capped at 64 events and 2 MiB. A slow
consumer loses the oldest delivery and can inspect the drop count. One owner
handles every WebSocket read, write, reconnect, and query-set change, while
`pump()` gives the calling program a bounded turn on that owner.

The Docker build pins Ring 1.27 at commit
`f88d95236319460327b05efcfdab7c342caa7d22`. The Live implementation pins the
`convex-rs-0.10.4-unversioned-sync` profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and endpoint `/api/sync`. The final
images run as user `65532:65532` with a read-only filesystem and no compiler,
package manager, Convex CLI, or delegated language runtime.

The language-local Docker test suite covers the JSON and whole-number helpers,
real loopback HTTP and WebSocket traffic, fragmented UTF-8, five forced
reconnects, recovery after structured failures, stale-delivery barriers, and a
real stopped reader. The adapter under `client/tests/conformance/` is test
infrastructure, not part of the public teaching API.

## Known Issues

1. The Live protocol is not documented as stable. This client is pinned to one
   observed sync profile, so hosted conformance remains important drift
   evidence.
2. Live authentication, `TransitionChunk` assembly, optimistic updates,
   mutation replay, and mutations or actions over the WebSocket are deferred.
3. Values cover this experiment's JSON-safe subset. Tagged Convex `Int64`,
   bytes, special floats, and negative zero are outside scope.
4. A Live handshake is a blocking libcurl call and can occupy the caller for up
   to the 15-second handshake budget. Under sustained backpressure, the client
   drops the oldest queued delivery rather than growing without bound.
5. Ring has no portable process exit-code API. If the test adapter cannot drain
   its close response within two seconds, it reports the failure on stderr and
   withholds the terminal event instead of exiting nonzero.
