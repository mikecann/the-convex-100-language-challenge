// Test-only fault injection.
//
// The shared conformance controller has to prove that Live really reconnects,
// not that it survives an idle socket, so it needs a way to sever the
// connection from the outside. That hook must not exist in a normal build of
// the client: an application has no business tearing down its own transport,
// and shipping the ability to do so would invite it.
//
// `moon.pkg` compiles this file only in debug builds, so a release build of the
// client genuinely does not contain it. The Dockerfile builds the canonical
// example with `--release` from a tree that has no adapter, and separately
// proves that a release build of the adapter fails to compile because this
// function is missing. That failure is the evidence: the hook is absent rather
// than merely unused.
//
// It is documented in `manifest.yaml` under `adapter.adapterOnlyCommands`.

///|
/// Sever the Live WebSocket so the next value must arrive over a new
/// connection. Test infrastructure only.
///
/// Returns once the old connection has been retired and the reconnect has been
/// scheduled, so a caller that mutates data after this returns is guaranteed to
/// be racing a genuinely new connection rather than the old one.
pub async fn Client::debug_disconnect(self : Client) -> Unit {
  guard !self.closed else { raise closed_error("client is closed") }
  self.live.debug_disconnect()
}

///|
async fn LiveManager::debug_disconnect(self : LiveManager) -> Unit {
  guard self.connected else {
    raise transport_error("Live WebSocket is not connected")
  }
  let completion = Completion::new()
  self.submit(DebugDisconnect(completion), completion)
}
