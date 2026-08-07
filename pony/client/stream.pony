use "net"

// The one place ordinary sockets enter this client.
//
// Everything above this file speaks to a `Stream`: something that accepts
// bytes and can be disposed of. That indirection is what makes the HTTP
// envelope rules, the WebSocket framing, and the whole Live state machine
// testable in-process with a scripted peer, with no listening port and no
// timing assumptions, while the production path is still a real socket.
//
// The interface is shaped so that Pony's own `TCPConnection` satisfies it
// structurally. There is no wrapper actor between the protocol code and the
// socket, and therefore no extra queue to reason about.

interface tag Stream
  """
  A connected byte stream. `TCPConnection` matches this without adaptation.
  """
  be write(data: ByteSeq)
  be dispose()

interface tag StreamSink
  """
  The owner of a connection attempt.

  `generation` identifies the connection this event belongs to. The Live owner
  opens a new connection on every reconnect and ignores anything carrying an
  older generation, which is what stops a slow event from a retired socket
  being applied to the current one.
  """
  be stream_opened(generation: U64, stream: Stream)
  be stream_data(generation: U64, data: Array[U8] val)
  be stream_closed(generation: U64, reason: String)
  be stream_throttled(generation: U64, throttled: Bool)

interface tag StreamOpener
  """
  Opens a connection to a Convex deployment.

  Implementations decide how `endpoint.secure` is honoured. `TcpStreamOpener`
  below refuses TLS outright rather than connecting in the clear, so a
  misconfigured build fails loudly instead of leaking a bearer token.
  """
  be open_stream(generation: U64, endpoint: ConvexEndpoint, sink: StreamSink)

class ConvexStreamNotify is TCPConnectionNotify
  """
  Translates Pony's socket callbacks into `StreamSink` events.

  It is public so the TLS opener in `client/tls` can wrap it in an
  `SSLConnection` without duplicating any of this logic.
  """

  let _generation: U64
  let _sink: StreamSink
  var _finished: Bool = false

  new iso create(generation: U64, sink: StreamSink) =>
    _generation = generation
    _sink = sink

  fun ref connected(conn: TCPConnection ref) =>
    _sink.stream_opened(_generation, conn)

  fun ref connect_failed(conn: TCPConnection ref) =>
    _finish("could not connect to the Convex deployment")

  fun ref auth_failed(conn: TCPConnection ref) =>
    _finish("TLS authentication failed")

  fun ref received(
    conn: TCPConnection ref,
    data: Array[U8] iso,
    times: USize)
    : Bool
  =>
    _sink.stream_data(_generation, consume data)
    // Keep reading. The protocol layers above bound their own buffers and drop
    // the connection when a peer exceeds them, so there is no unbounded growth
    // to defend against by pausing here.
    true

  fun ref closed(conn: TCPConnection ref) =>
    _finish("the Convex deployment closed the connection")

  fun ref throttled(conn: TCPConnection ref) =>
    _sink.stream_throttled(_generation, true)

  fun ref unthrottled(conn: TCPConnection ref) =>
    _sink.stream_throttled(_generation, false)

  fun ref _finish(reason: String) =>
    // Pony can report both a failed connect and a close for the same socket.
    // The sink must see exactly one terminal event per generation.
    if not _finished then
      _finished = true
      _sink.stream_closed(_generation, reason)
    end

actor TcpStreamOpener
  """
  Plain TCP. This is the whole non-TLS transport for the client.
  """

  let _auth: TCPConnectAuth

  new create(auth: AmbientAuth) =>
    _auth = TCPConnectAuth(auth)

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    if endpoint.secure then
      // Falling back to plaintext for an `https://` URL would send the bearer
      // token in the clear, so refuse instead.
      sink.stream_closed(
        generation, "this build has no TLS transport for an https deployment")
      return
    end
    TCPConnection(
      _auth,
      ConvexStreamNotify(generation, sink),
      endpoint.host,
      endpoint.service)
