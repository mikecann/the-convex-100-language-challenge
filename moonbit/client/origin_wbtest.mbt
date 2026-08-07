// Deployment URL acceptance.
//
// The normalised origin is used twice - as the HTTP origin for every function
// call and as the base the Live socket upgrades from - so anything this
// function lets through changes where bytes go. These are white-box tests
// because the interesting behaviour is the refusal itself, and a refusal is
// easier to read against the function than through a client that never
// connects.

///|
/// Normalise `url` and report either the result or the failure family and
/// message, so each case below asserts on a single string.
fn origin_outcome(url : String) -> String {
  normalise_origin(url) catch {
    ConvexError(info) => info.kind.to_string() + ": " + info.message
  }
}

///|
test "an ordinary deployment origin is accepted and its trailing slash trimmed" {
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud"),
    "https://example.convex.cloud",
  )
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud/"),
    "https://example.convex.cloud",
  )
  // A port is part of the authority, so it survives.
  @test.assert_eq(
    origin_outcome("http://127.0.0.1:3210"),
    "http://127.0.0.1:3210",
  )
}

///|
test "a URL that is not an http origin is refused" {
  let refused = [
    "", "example.convex.cloud", "ws://example.convex.cloud", "https://",
  ]
  for url in refused {
    @test.assert_eq(origin_outcome(url).has_prefix("ProtocolError"), true)
  }
}

///|
test "anything past the authority is refused rather than trimmed away" {
  // A path would send `/api/query` somewhere else entirely, and the Live
  // upgrade would disagree with the HTTP calls about where the deployment is.
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud/api").contains("path"),
    true,
  )
  // Several URL parsers treat a backslash as a path separator, so accepting one
  // would leave the check above depending on whose parser saw the string next.
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud\\api").contains("path"),
    true,
  )
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud?token=abc").contains("query"),
    true,
  )
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud#fragment").contains("fragment"),
    true,
  )
  @test.assert_eq(
    origin_outcome("https://example.convex.cloud ").contains("spaces"),
    true,
  )
}

///|
test "a credential in the URL is refused instead of being silently discarded" {
  // This client sends its bearer token through `set_auth` and never through the
  // origin, so a URL credential would be dropped. Accepting the URL would make
  // that look like authentication that happened.
  let outcome = origin_outcome("https://deploy:secret@example.convex.cloud")
  @test.assert_eq(outcome.has_prefix("ProtocolError"), true)
  @test.assert_eq(outcome.contains("userinfo"), true)
  // The refusal must not quote the credential back into a message that may be
  // logged.
  @test.assert_eq(outcome.contains("secret"), false)
}
