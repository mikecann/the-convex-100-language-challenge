use "pony_test"

// The client package's own test runner, following the Pony convention of a
// `_test.pony` that owns a `Main` inside the library package. Building this
// package produces the test executable; a program that uses the library gets
// its own `Main` instead.
//
// Every test here is deterministic and runs entirely in process. Nothing binds
// a port, nothing sleeps, and nothing talks to a Convex deployment, so a
// failure is always a real failure rather than a slow machine.

actor Main is TestList
  new create(env: Env) =>
    PonyTest(env, this)

  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    // Codecs, checked against published vectors.
    test(_TestBase64)
    test(_TestSha1)
    test(_TestWebsocketAccept)
    test(_TestUtf8)
    test(_TestEndpoint)

    // The JSON layer, including the exact-number promise Convex relies on.
    test(_TestJsonRoundTrip)
    test(_TestJsonStrict)
    test(_TestJsonIntegral)
    test(_TestJsonObjects)

    // HTTP framing and its bounds.
    test(_TestHttpRequest)
    test(_TestHttpResponse)
    test(_TestHttpChunked)
    test(_TestHttpStrict)
    test(_TestHttpCloseDelimited)

    // RFC 6455 framing.
    test(_TestWsHandshake)
    test(_TestWsHandshakeRejection)
    test(_TestWsFraming)
    test(_TestWsFragments)
    test(_TestWsStrict)
    test(_TestWsClientFrames)

    // The public client over a scripted peer.
    test(_TestClientHttp)
    test(_TestClientAuth)

    // Live acceptance.
    test(_TestLiveLifecycle)
    test(_TestLiveReconnect)
    test(_TestLiveBackpressure)
    test(_TestLiveDeadlines)
