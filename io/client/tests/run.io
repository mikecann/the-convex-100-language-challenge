#!/usr/local/bin/io
//
// Language-local test entry point.
//
// Loads the client, the loopback harness and every suite, then exits non-zero
// if any check failed. Nothing here contacts a Convex deployment: the socket
// tests all run against the harness peer on the loopback interface.
//

ConvexTestRunner := Object clone do(
    base := method(
        script := System launchScript
        if(script isNil, ".", script pathComponent)
    )

    load := method(relative, Lobby doFile(ConvexTestRunner base .. "/" .. relative))
)

ConvexTestRunner load("../convex.io")
ConvexTestRunner load("harness.io")
ConvexTestRunner load("unit_test.io")
ConvexTestRunner load("http_peer_test.io")
ConvexTestRunner load("live_peer_test.io")

// The adapter refuses to start its own event loop when this is set, so the
// suite can exercise its queue and command handling in process.
System setEnvironmentVariable("CONVEX_ADAPTER_TEST_ONLY", "1")
ConvexTestRunner load("conformance/adapter.io")
ConvexTestRunner load("conformance/adapter_test.io")

// The example is loaded, not copied: the tests below run the same source the
// README and the website display.
Lobby ConvexExampleLoadOnly := true
ConvexTestRunner load("../../examples/basics/main.io")
ConvexTestRunner load("../../examples/basics/main_test.io")

ConvexUnitTest run
ConvexHttpPeerTest run
ConvexLivePeerTest run
ConvexAdapterTest run
ConvexExampleTest run

System exit(if(ConvexTest report > 0, 1, 0))
