use "files"
use "net"
use "net_ssl"
use "../../client"

// TLS lives in its own package on purpose.
//
// Convex protocol behaviour stays outside this package. `net_ssl` is confined
// here so a change to its API can affect ordinary TLS transport but not JSON,
// HTTP envelopes, or the sync state machine. Live separately links libcrypto
// for operating-system-backed WebSocket entropy.
//
// This is the ordinary-transport exemption the project allows: TLS is normal
// library work for a language, and nothing Convex specific happens in this
// file.

actor TlsStreamOpener
  """
  Opens either a plain or a TLS connection, chosen by the deployment URL.

  A deployment URL is the security boundary here. An `https://` URL that could
  not be given a verified TLS context fails the connection rather than
  downgrading, because a silent downgrade would put the bearer token on the
  wire in the clear.
  """

  let _connect_auth: TCPConnectAuth
  let _context: (SSLContext val | None)
  let _context_error: String

  new create(
    auth: AmbientAuth,
    certificate_authority: String = "/etc/ssl/certs/ca-certificates.crt")
  =>
    _connect_auth = TCPConnectAuth(auth)
    var built: (SSLContext val | None) = None
    var failure = ""
    try
      let bundle = FilePath(FileAuth(auth), certificate_authority)
      built =
        recover val
          let context = SSLContext
          // Verify the server chain and hostname. Without this a TLS
          // connection proves only that something answered.
          context.set_client_verify(true)
          context.set_authority(bundle)?
          context
        end
    else
      failure = "could not load the certificate authority bundle at " +
        certificate_authority
    end
    _context = built
    _context_error = failure

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    if not endpoint.secure then
      TCPConnection(
        _connect_auth,
        ConvexStreamNotify(generation, sink),
        endpoint.host,
        endpoint.service)
      return
    end

    match _context
    | let context: SSLContext val =>
      try
        let ssl = context.client(endpoint.host)?
        TCPConnection(
          _connect_auth,
          SSLConnection(ConvexStreamNotify(generation, sink), consume ssl),
          endpoint.host,
          endpoint.service)
      else
        sink.stream_closed(
          generation, "could not start a TLS session for " + endpoint.host)
      end
    | None =>
      sink.stream_closed(generation, _context_error)
    end
