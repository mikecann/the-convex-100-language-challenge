' Deadline bounded TCP and TLS stream implementation.

#include once "net.bi"

#inclib "ssl"
#inclib "crypto"

declare function sys_socket cdecl alias "socket" ( _
  byval domain as long, _
  byval kind as long, _
  byval protocol as long) as long
declare function sys_connect cdecl alias "connect" ( _
  byval fd as long, _
  byval address as any ptr, _
  byval length as ulong) as long
declare function sys_bind cdecl alias "bind" ( _
  byval fd as long, _
  byval address as any ptr, _
  byval length as ulong) as long
declare function sys_listen cdecl alias "listen" ( _
  byval fd as long, _
  byval backlog as long) as long
declare function sys_accept cdecl alias "accept" ( _
  byval fd as long, _
  byval address as any ptr, _
  byval length as ulong ptr) as long
declare function sys_close cdecl alias "close" (byval fd as long) as long
declare function sys_shutdown cdecl alias "shutdown" ( _
  byval fd as long, _
  byval how as long) as long
declare function sys_read cdecl alias "read" ( _
  byval fd as long, _
  byval buffer as any ptr, _
  byval count as uinteger) as integer
declare function sys_write cdecl alias "write" ( _
  byval fd as long, _
  byval buffer as any ptr, _
  byval count as uinteger) as integer
declare function sys_poll cdecl alias "poll" ( _
  byval entries as PollFdT ptr, _
  byval count as ulongint, _
  byval timeoutMs as long) as long
declare function sys_fcntl cdecl alias "fcntl" ( _
  byval fd as long, _
  byval command as long, _
  byval argument as long) as long
declare function sys_setsockopt cdecl alias "setsockopt" ( _
  byval fd as long, _
  byval level as long, _
  byval option_name as long, _
  byval value as any ptr, _
  byval length as ulong) as long
declare function sys_getsockopt cdecl alias "getsockopt" ( _
  byval fd as long, _
  byval level as long, _
  byval option_name as long, _
  byval value as any ptr, _
  byval length as ulong ptr) as long
declare function sys_getaddrinfo cdecl alias "getaddrinfo" ( _
  byval node as zstring ptr, _
  byval service as zstring ptr, _
  byval hints as AddrInfoT ptr, _
  byval result as AddrInfoT ptr ptr) as long
declare sub sys_freeaddrinfo cdecl alias "freeaddrinfo" (byval info as AddrInfoT ptr)
declare function sys_gai_strerror cdecl alias "gai_strerror" ( _
  byval code as long) as zstring ptr
declare function sys_errno_location cdecl alias "__errno_location" () as long ptr
declare function sys_htons cdecl alias "htons" (byval value as ushort) as ushort

' OpenSSL 3 entry points. SSL_CTX_set_min_proto_version and
' SSL_set_tlsext_host_name are macros in the C headers, so they are expressed
' here as the SSL_ctrl calls they expand to.
const SSL_CTRL_SET_TLSEXT_HOSTNAME = 55
const TLSEXT_NAMETYPE_host_name = 0
const SSL_CTRL_SET_MIN_PROTO_VERSION = 123
const TLS1_2_VERSION = &h0303
const SSL_VERIFY_PEER = 1
const SSL_ERROR_NONE = 0
const SSL_ERROR_WANT_READ = 2
const SSL_ERROR_WANT_WRITE = 3
const SSL_ERROR_ZERO_RETURN = 6
const SSL_ERROR_SYSCALL = 5

declare function OPENSSL_init_ssl cdecl alias "OPENSSL_init_ssl" ( _
  byval options as ulongint, _
  byval settings as any ptr) as long
declare function TLS_client_method cdecl alias "TLS_client_method" () as any ptr
declare function SSL_CTX_new cdecl alias "SSL_CTX_new" (byval method as any ptr) as any ptr
declare sub SSL_CTX_free cdecl alias "SSL_CTX_free" (byval ctx as any ptr)
declare function SSL_CTX_set_default_verify_paths cdecl _
  alias "SSL_CTX_set_default_verify_paths" (byval ctx as any ptr) as long
declare sub SSL_CTX_set_verify cdecl alias "SSL_CTX_set_verify" ( _
  byval ctx as any ptr, _
  byval mode as long, _
  byval callback as any ptr)
declare function SSL_CTX_ctrl cdecl alias "SSL_CTX_ctrl" ( _
  byval ctx as any ptr, _
  byval command as long, _
  byval argument as longint, _
  byval pointer_argument as any ptr) as longint
declare function SSL_new cdecl alias "SSL_new" (byval ctx as any ptr) as any ptr
declare sub SSL_free cdecl alias "SSL_free" (byval ssl as any ptr)
declare function SSL_set_fd cdecl alias "SSL_set_fd" ( _
  byval ssl as any ptr, _
  byval fd as long) as long
declare function SSL_ctrl cdecl alias "SSL_ctrl" ( _
  byval ssl as any ptr, _
  byval command as long, _
  byval argument as longint, _
  byval pointer_argument as any ptr) as longint
declare function SSL_set1_host cdecl alias "SSL_set1_host" ( _
  byval ssl as any ptr, _
  byval hostname as zstring ptr) as long
declare function SSL_connect cdecl alias "SSL_connect" (byval ssl as any ptr) as long
declare function SSL_read cdecl alias "SSL_read" ( _
  byval ssl as any ptr, _
  byval buffer as any ptr, _
  byval length as long) as long
declare function SSL_write cdecl alias "SSL_write" ( _
  byval ssl as any ptr, _
  byval buffer as any ptr, _
  byval length as long) as long
declare function SSL_get_error cdecl alias "SSL_get_error" ( _
  byval ssl as any ptr, _
  byval result as long) as long
declare function SSL_shutdown cdecl alias "SSL_shutdown" (byval ssl as any ptr) as long
declare function SSL_get_verify_result cdecl alias "SSL_get_verify_result" ( _
  byval ssl as any ptr) as longint
declare function ERR_get_error cdecl alias "ERR_get_error" () as ulongint
declare sub ERR_error_string_n cdecl alias "ERR_error_string_n" ( _
  byval code as ulongint, _
  byval buffer as zstring ptr, _
  byval length as uinteger)

dim shared as boolean NetReady

sub NetInitialize()
  if NetReady then
    exit sub
  end if
  OPENSSL_init_ssl(0, 0)
  NetReady = true
end sub

private function LastErrno() as long
  return *sys_errno_location()
end function

private function OpenSslReason(byref prefix as string) as string
  dim as ulongint code = ERR_get_error()
  if code = 0 then
    return prefix
  end if
  dim as zstring * 256 buffer
  ERR_error_string_n(code, @buffer, 256)
  return prefix & ": " & buffer
end function

function ReadFd( _
    byval fd as long, _
    byval buffer as any ptr, _
    byval capacity as long) as long
  dim as integer received = sys_read(fd, buffer, capacity)
  if received > 0 then
    return cast(long, received)
  end if
  if received = 0 then
    return 0
  end if
  dim as long code = LastErrno()
  if code = EAGAIN_ERRNO orelse code = EINTR_ERRNO then
    return -1
  end if
  return -2
end function

function CloseFd(byval fd as long) as long
  if fd < 0 then
    return 0
  end if
  return sys_close(fd)
end function

function PollDescriptor( _
    byval fd as long, _
    byval events as short, _
    byval timeoutMs as long) as long
  if fd < 0 then
    return -1
  end if
  dim as PollFdT entry
  entry.fd = fd
  entry.events = events
  entry.revents = 0
  dim as long ready = sys_poll(@entry, 1, timeoutMs)
  ' A signal must not be mistaken for a transport failure.
  if ready < 0 andalso LastErrno() = EINTR_ERRNO then
    return 0
  end if
  return ready
end function

function MakeNonBlocking(byval fd as long) as boolean
  dim as long flags = sys_fcntl(fd, F_GETFL, 0)
  if flags < 0 then
    return false
  end if
  return sys_fcntl(fd, F_SETFL, flags or O_NONBLOCK) >= 0
end function

sub StreamReset(byref stream as ConvexStream)
  stream.fd = -1
  stream.ssl = 0
  stream.ctx = 0
  stream.closed = false
end sub

function StreamIsOpen(byref stream as ConvexStream) as boolean
  return stream.fd >= 0 andalso (not stream.closed)
end function

sub StreamClose(byref stream as ConvexStream)
  if stream.ssl <> 0 then
    ' One non-blocking SSL_shutdown attempt only. Waiting for the peer's
    ' close_notify would make close unbounded when the peer is stalled.
    SSL_shutdown(stream.ssl)
    SSL_free(stream.ssl)
    stream.ssl = 0
  end if
  if stream.ctx <> 0 then
    SSL_CTX_free(stream.ctx)
    stream.ctx = 0
  end if
  if stream.fd >= 0 then
    sys_shutdown(stream.fd, SHUT_RDWR)
    sys_close(stream.fd)
    stream.fd = -1
  end if
  stream.closed = true
end sub

private function ConnectTcp( _
    byref host as string, _
    byval port as long, _
    byval deadline as longint, _
    byref fault as ConvexFault) as long
  dim as AddrInfoT hints
  hints.ai_family = AF_UNSPEC
  hints.ai_socktype = SOCK_STREAM
  hints.ai_protocol = IPPROTO_TCP
  dim as AddrInfoT ptr results
  dim as zstring * 256 nodeName
  dim as zstring * 16 serviceName
  if len(host) >= 256 then
    FaultSet(fault, FAULT_PROTOCOL, "Convex host name is too long")
    return -1
  end if
  nodeName = host
  serviceName = FormatInteger(port)
  dim as long lookup = sys_getaddrinfo(@nodeName, @serviceName, @hints, @results)
  if lookup <> 0 orelse results = 0 then
    dim as zstring ptr detail = sys_gai_strerror(lookup)
    dim as string message = "could not resolve " & host
    if detail <> 0 then
      message &= ": " & *detail
    end if
    FaultSet(fault, FAULT_TRANSPORT, message)
    return -1
  end if

  dim as long fd = -1
  dim as AddrInfoT ptr candidate = results
  while candidate <> 0
    fd = sys_socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol)
    if fd >= 0 then
      if MakeNonBlocking(fd) then
        dim as long enabled = 1
        sys_setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, @enabled, sizeof(long))
        dim as long started = sys_connect(fd, candidate->ai_addr, candidate->ai_addrlen)
        if started = 0 then
          exit while
        end if
        if LastErrno() = EINPROGRESS then
          dim as boolean established = false
          while MonotonicMs() < deadline
            dim as long remaining = cast(long, deadline - MonotonicMs())
            if remaining > 200 then
              remaining = 200
            end if
            if PollDescriptor(fd, POLLOUT, remaining) > 0 then
              dim as long pending = 0
              dim as ulong length = sizeof(long)
              if sys_getsockopt(fd, SOL_SOCKET, SO_ERROR, @pending, @length) = 0 andalso _
                 pending = 0 then
                established = true
              end if
              exit while
            end if
          wend
          if established then
            exit while
          end if
        end if
      end if
      sys_close(fd)
      fd = -1
    end if
    candidate = candidate->ai_next
  wend
  sys_freeaddrinfo(results)
  if fd < 0 then
    FaultSet(fault, FAULT_TRANSPORT, "could not connect to " & host)
  end if
  return fd
end function

function StreamConnect( _
    byref stream as ConvexStream, _
    byref host as string, _
    byval port as long, _
    byval useTls as boolean, _
    byval timeoutMs as long, _
    byref fault as ConvexFault) as boolean
  NetInitialize()
  StreamReset(stream)
  dim as longint deadline = MonotonicMs() + timeoutMs
  dim as long fd = ConnectTcp(host, port, deadline, fault)
  if fd < 0 then
    return false
  end if
  stream.fd = fd
  if not useTls then
    return true
  end if

  stream.ctx = SSL_CTX_new(TLS_client_method())
  if stream.ctx = 0 then
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("could not create a TLS context"))
    StreamClose(stream)
    return false
  end if
  ' Refuse anything below TLS 1.2 and require a verified chain plus a matching
  ' host name. Convex is reached over the public internet in hosted runs.
  SSL_CTX_ctrl(stream.ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, 0)
  if SSL_CTX_set_default_verify_paths(stream.ctx) <> 1 then
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("could not load CA certificates"))
    StreamClose(stream)
    return false
  end if
  SSL_CTX_set_verify(stream.ctx, SSL_VERIFY_PEER, 0)

  stream.ssl = SSL_new(stream.ctx)
  if stream.ssl = 0 then
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("could not create a TLS session"))
    StreamClose(stream)
    return false
  end if
  dim as zstring * 256 hostName
  hostName = host
  if SSL_ctrl(stream.ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, _
              TLSEXT_NAMETYPE_host_name, @hostName) <> 1 then
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("could not set the TLS server name"))
    StreamClose(stream)
    return false
  end if
  if SSL_set1_host(stream.ssl, @hostName) <> 1 then
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("could not pin the TLS host name"))
    StreamClose(stream)
    return false
  end if
  if SSL_set_fd(stream.ssl, stream.fd) <> 1 then
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("could not attach the TLS session"))
    StreamClose(stream)
    return false
  end if

  do
    dim as long result = SSL_connect(stream.ssl)
    if result = 1 then
      exit do
    end if
    dim as long reason = SSL_get_error(stream.ssl, result)
    if reason = SSL_ERROR_WANT_READ orelse reason = SSL_ERROR_WANT_WRITE then
      dim as longint remaining = deadline - MonotonicMs()
      if remaining <= 0 then
        FaultSet(fault, FAULT_TRANSPORT, "TLS handshake timed out")
        StreamClose(stream)
        return false
      end if
      if remaining > 200 then
        remaining = 200
      end if
      dim as short events = POLLIN
      if reason = SSL_ERROR_WANT_WRITE then
        events = POLLOUT
      end if
      PollDescriptor(stream.fd, events, cast(long, remaining))
      continue do
    end if
    FaultSet(fault, FAULT_TRANSPORT, OpenSslReason("TLS handshake failed"))
    StreamClose(stream)
    return false
  loop
  if SSL_get_verify_result(stream.ssl) <> 0 then
    FaultSet(fault, FAULT_TRANSPORT, "TLS certificate verification failed")
    StreamClose(stream)
    return false
  end if
  return true
end function

function StreamRead( _
    byref stream as ConvexStream, _
    byval buffer as ubyte ptr, _
    byval capacity as long, _
    byval deadline as longint, _
    byref reason as string) as long
  if not StreamIsOpen(stream) then
    reason = "stream is closed"
    return -1
  end if
  do
    if stream.ssl <> 0 then
      dim as long received = SSL_read(stream.ssl, buffer, capacity)
      if received > 0 then
        return received
      end if
      dim as long status = SSL_get_error(stream.ssl, received)
      select case status
        case SSL_ERROR_ZERO_RETURN
          reason = "peer closed the TLS stream"
          return -2
        case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE
          dim as short events = POLLIN
          if status = SSL_ERROR_WANT_WRITE then
            events = POLLOUT
          end if
          dim as longint remaining = deadline - MonotonicMs()
          if remaining <= 0 then
            return 0
          end if
          if remaining > 50 then
            remaining = 50
          end if
          PollDescriptor(stream.fd, events, cast(long, remaining))
          if MonotonicMs() >= deadline then
            return 0
          end if
          continue do
        case else
          reason = OpenSslReason("TLS read failed")
          return -1
      end select
    end if

    dim as integer received = sys_read(stream.fd, buffer, capacity)
    if received > 0 then
      return cast(long, received)
    end if
    if received = 0 then
      reason = "peer closed the connection"
      return -2
    end if
    dim as long code = LastErrno()
    if code <> EAGAIN_ERRNO andalso code <> EINTR_ERRNO then
      reason = "socket read failed with errno " & FormatInteger(code)
      return -1
    end if
    dim as longint remaining = deadline - MonotonicMs()
    if remaining <= 0 then
      return 0
    end if
    if remaining > 50 then
      remaining = 50
    end if
    PollDescriptor(stream.fd, POLLIN, cast(long, remaining))
    if MonotonicMs() >= deadline then
      return 0
    end if
  loop
end function

function StreamWriteAll( _
    byref stream as ConvexStream, _
    byref payload as string, _
    byval deadline as longint, _
    byref reason as string) as boolean
  if not StreamIsOpen(stream) then
    reason = "stream is closed"
    return false
  end if
  dim as long total = len(payload)
  dim as long offset = 0
  while offset < total
    if MonotonicMs() >= deadline then
      reason = "write timed out"
      return false
    end if
    dim as any ptr chunk = @payload[offset]
    dim as long sent
    if stream.ssl <> 0 then
      sent = SSL_write(stream.ssl, chunk, total - offset)
      if sent <= 0 then
        dim as long status = SSL_get_error(stream.ssl, sent)
        if status = SSL_ERROR_WANT_READ orelse status = SSL_ERROR_WANT_WRITE then
          dim as short events = POLLOUT
          if status = SSL_ERROR_WANT_READ then
            events = POLLIN
          end if
          PollDescriptor(stream.fd, events, 20)
          continue while
        end if
        reason = OpenSslReason("TLS write failed")
        return false
      end if
    else
      dim as integer written = sys_write(stream.fd, chunk, total - offset)
      if written <= 0 then
        dim as long code = LastErrno()
        if code = EAGAIN_ERRNO orelse code = EINTR_ERRNO then
          PollDescriptor(stream.fd, POLLOUT, 20)
          continue while
        end if
        reason = "socket write failed with errno " & FormatInteger(code)
        return false
      end if
      sent = cast(long, written)
    end if
    offset += sent
  wend
  return true
end function

function WriteAllFd( _
    byval fd as long, _
    byref payload as string, _
    byval deadline as longint, _
    byref reason as string) as boolean
  dim as long total = len(payload)
  dim as long offset = 0
  while offset < total
    if MonotonicMs() >= deadline then
      reason = "write timed out"
      return false
    end if
    dim as integer written = sys_write(fd, @payload[offset], total - offset)
    if written > 0 then
      offset += cast(long, written)
      continue while
    end if
    dim as long code = LastErrno()
    if code <> EAGAIN_ERRNO andalso code <> EINTR_ERRNO then
      reason = "write failed with errno " & FormatInteger(code)
      return false
    end if
    ' A stalled reader must not turn into an unbounded wait, so the remaining
    ' deadline governs how long POLLOUT is awaited.
    dim as longint remaining = deadline - MonotonicMs()
    if remaining > 20 then
      remaining = 20
    end if
    if remaining <= 0 then
      reason = "write timed out"
      return false
    end if
    PollDescriptor(fd, POLLOUT, cast(long, remaining))
  wend
  return true
end function

' Parse a dotted quad so the adapter's listen address never depends on a name
' service inside a network isolated verification container.
private function ParseDottedQuad(byref text as string, byref address as ulong) as boolean
  address = 0
  dim as long octetCount = 0
  dim as long value = 0
  dim as boolean sawDigit = false
  dim as ulong accumulated = 0
  for index as integer = 0 to len(text)
    dim as long octet = -1
    if index < len(text) then
      octet = text[index]
    end if
    if octet >= asc("0") andalso octet <= asc("9") then
      value = value * 10 + (octet - asc("0"))
      if value > 255 then
        return false
      end if
      sawDigit = true
    elseif octet = asc(".") orelse octet = -1 then
      if not sawDigit then
        return false
      end if
      accumulated = (accumulated shl 8) or cast(ulong, value)
      octetCount += 1
      value = 0
      sawDigit = false
      if octet = -1 then
        exit for
      end if
    else
      return false
    end if
  next
  if octetCount <> 4 then
    return false
  end if
  ' Convert to network byte order without depending on htonl.
  address = ((accumulated and &hff) shl 24) or _
            (((accumulated shr 8) and &hff) shl 16) or _
            (((accumulated shr 16) and &hff) shl 8) or _
            ((accumulated shr 24) and &hff)
  return true
end function

function ListenLoopback( _
    byref address as string, _
    byref fault as ConvexFault) as long
  dim as integer separator = instrrev(address, ":")
  if separator <= 1 then
    FaultSet(fault, FAULT_PROTOCOL, "ADAPTER_LISTEN must be host:port")
    return -1
  end if
  dim as string host = left(address, separator - 1)
  dim as ulongint port
  if not DecimalToUlong(mid(address, separator + 1), port) orelse port = 0 orelse _
     port > 65535 then
    FaultSet(fault, FAULT_PROTOCOL, "ADAPTER_LISTEN port is out of range")
    return -1
  end if
  dim as ulong hostAddress
  if not ParseDottedQuad(host, hostAddress) then
    FaultSet(fault, FAULT_PROTOCOL, "ADAPTER_LISTEN host must be an IPv4 address")
    return -1
  end if

  dim as long fd = sys_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  if fd < 0 then
    FaultSet(fault, FAULT_TRANSPORT, "could not create the adapter listener")
    return -1
  end if
  dim as long enabled = 1
  sys_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, @enabled, sizeof(long))
  dim as SockAddrInT bindTo
  bindTo.sin_family = AF_INET
  bindTo.sin_port = sys_htons(cast(ushort, port))
  bindTo.sin_addr = hostAddress
  if sys_bind(fd, @bindTo, sizeof(SockAddrInT)) <> 0 then
    FaultSet(fault, FAULT_TRANSPORT, "could not bind " & address)
    sys_close(fd)
    return -1
  end if
  if sys_listen(fd, 1) <> 0 then
    FaultSet(fault, FAULT_TRANSPORT, "could not listen on " & address)
    sys_close(fd)
    return -1
  end if
  return fd
end function

function AcceptOne( _
    byval listener as long, _
    byval timeoutMs as long, _
    byref fault as ConvexFault) as long
  dim as longint deadline = MonotonicMs() + timeoutMs
  while MonotonicMs() < deadline
    dim as longint remaining = deadline - MonotonicMs()
    if remaining > 200 then
      remaining = 200
    end if
    if PollDescriptor(listener, POLLIN, cast(long, remaining)) > 0 then
      dim as SockAddrInT peer
      dim as ulong length = sizeof(SockAddrInT)
      dim as long fd = sys_accept(listener, @peer, @length)
      if fd >= 0 then
        ' The controller connection shares the adapter's bounded write path, so
        ' it must never block the output gate on a stalled reader.
        MakeNonBlocking(fd)
        return fd
      end if
      dim as long code = LastErrno()
      if code <> EAGAIN_ERRNO andalso code <> EINTR_ERRNO then
        FaultSet(fault, FAULT_TRANSPORT, "accept failed with errno " & FormatInteger(code))
        return -1
      end if
    end if
  wend
  FaultSet(fault, FAULT_TRANSPORT, "no controller connected before the deadline")
  return -1
end function

' Structure layouts are an ABI promise, not an implementation detail. Assert
' them so a future base image change fails a unit test rather than a live run.
function NetSelfTest(byref reason as string) as boolean
  reason = ""
  if sizeof(PollFdT) <> 8 then
    reason = "pollfd layout drifted"
    return false
  end if
  if sizeof(SockAddrInT) <> 16 then
    reason = "sockaddr_in layout drifted"
    return false
  end if
  if sizeof(AddrInfoT) <> 48 then
    reason = "addrinfo layout drifted"
    return false
  end if
  dim as ulong parsed
  if not ParseDottedQuad("127.0.0.1", parsed) then
    reason = "loopback address failed to parse"
    return false
  end if
  if parsed <> &h0100007f then
    reason = "loopback address parsed to the wrong network order"
    return false
  end if
  if ParseDottedQuad("127.0.0.256", parsed) then
    reason = "an out of range octet was accepted"
    return false
  end if
  if ParseDottedQuad("127.0.0", parsed) then
    reason = "a short address was accepted"
    return false
  end if
  if ParseDottedQuad("127.0.0.1.", parsed) then
    reason = "a trailing dot was accepted"
    return false
  end if
  return true
end function
