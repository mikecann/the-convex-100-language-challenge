/** Test-only probe executed inside the final runtime rootfs.
 *
 * A minimal image can pass every build-stage check and still fail the first
 * time it opens a TLS connection, because the certificate bundle or the
 * runtime's TLS module was never copied. This loads the default trust store
 * and constructs a verifying TLS socket from the runtime image itself, so a
 * missing bundle or module is found during the build rather than during
 * hosted verification. It is deleted before either entrypoint image ships. */
class TlsProbe {
  public static function main():Void {
    var authorities = sys.ssl.Certificate.loadDefaults();
    if (authorities == null) throw "the runtime image has no default certificate authorities";
    if (authorities.subject("CN") == null) throw "the default certificate bundle carries no subjects";

    // Complete a real verified handshake through the same deadline-aware dial
    // path as the client. Merely constructing a TLS object would not prove the
    // copied NDLL, OpenSSL closure, DNS and CA bundle can work together.
    var socket = SocketTransport.dial(new DeploymentUrl("https://convex.cloud"), 10.0);
    SocketTransport.closeQuietly(socket);

    // Prove the client's own random source is readable as the unprivileged
    // runtime UID. Read-only filesystem behaviour is exercised later by the
    // root-owned final-image verification rather than claimed by this build.
    if (WebSocketTransport.secureRandom(16).length != 16) throw "the runtime image cannot read randomness";
    Sys.println("tls probe ok");
  }
}
