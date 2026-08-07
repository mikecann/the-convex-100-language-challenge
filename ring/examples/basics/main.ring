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
