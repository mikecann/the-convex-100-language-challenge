# Convex from Ring

This demonstration uses Ring to call Convex's documented JSON HTTP endpoints and
to keep a reactive query current over a real WebSocket connection to Convex's
sync socket.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.ring`](examples/basics/main.ring) is the canonical
example. It reads a fresh counter room over HTTP, starts Live before changing
anything, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that exact
runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared verification | Ring builds the Convex request envelopes and classifies every response, over libcurl's TLS-verified HTTP. Query, mutation, action, bearer-token lifecycle, log lines and structured function errors are implemented. |
| Live | Awaiting shared verification | Ring owns the Convex sync protocol: query-set versions, transitions, reconnect ownership, hydration suppression and publication. libcurl carries the RFC 6455 frames underneath. |

No capability badge is earned until root-owned local and hosted black-box
conformance passes. A Docker build or a language-local test does not earn one.
Nothing in this directory has been executed in Docker yet.

## The basic example

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

## Verify it in Docker

```sh
./run test ring
./run verify-example ring
./run verify ring
./run verify-hosted ring
./run verify-all ring
```

`test` builds Ring 1.27 from source with the RingLibCurl, RingLibuv and
RingOpenSSL extensions, then runs the deterministic unit suite, a real loopback
HTTP and WebSocket suite, a genuine stopped-reader socket test, and the
adapter's stdin/stdout smoke check. `verify-example` runs the canonical source
above in its minimal image and compares stdout with the universal transcript.
The remaining commands are root-owned shared gates against the approved local
and hosted deployments.

## Conformance and protocol notes

The test-only executable under `client/tests/conformance/` speaks NDJSON adapter
protocol v1 on stdin/stdout and over the TCP mode the shared harness uses. It
calls the real Ring client for every operation and reserves stdout for protocol
events. Its adapter-only `debugDisconnect` command lets the shared controller
prove five real reconnects; it is not part of the educational client API.

HTTP uses Convex's documented `format: "json"` endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`. That realtime
protocol is not documented as stable, so hosted verification remains required.

Ring itself is pinned to `ring-lang/ring` tag `v1.27`, commit
`f88d95236319460327b05efcfdab7c342caa7d22`, built inside Docker with the
upstream build scripts. Both runtime images run as `65532:65532` on a read-only
filesystem with all Linux capabilities dropped, and they contain no compiler,
package manager, Convex CLI or delegated language runtime.

## Limitations

- RFC 6455 framing, masking and the upgrade handshake are libcurl's. Ring owns
  everything above that: message reassembly and its byte budget, the query-set
  state machine, reconnect ownership, and every publication decision. libcurl
  must be built with WebSocket support, which is the default from curl 8.11.
- Live authentication, `TransitionChunk` assembly, optimistic updates, mutation
  replay and WebSocket writes are deferred. A chunk is treated as recoverable
  protocol drift rather than being silently ignored.
- Values are limited to this experiment's JSON-safe subset. Tagged Convex
  `Int64`, bytes, special floats and negative zero are outside scope.
- The Live handshake is a blocking libcurl call, so a reconnect can stall the
  adapter's controller stream for up to its fifteen second handshake budget.
- Ring has no portable process exit code, so an adapter that misses its two
  second close deadline reports the failure on stderr and by withholding the
  terminal event instead of exiting non-zero.
- Delivery buffering is deliberate and owned by the client: a bounded 64-event,
  2 MiB FIFO that drops the oldest delivery for a slow consumer and reports the
  drop count. The conformance adapter adds its own newest-16 output queue with a
  6 MiB byte budget that reserves four slots and 64 KiB for control events, and
  it rechecks subscription ownership immediately before handing bytes to libuv
  so an unsubscribe or same-ID replacement can never be crossed by a stale
  value.
- A hostile TLS peer fixture is deferred because Ring has no TLS server
  primitive. TLS is covered instead by pinned verification settings, a real
  handshake probe executed inside the final runtime image, and a negative test
  that requires an `https` request to a plaintext listener to fail as a
  transport error.
- Root-owned local and hosted conformance remain the only gates that can award
  a capability badge.
