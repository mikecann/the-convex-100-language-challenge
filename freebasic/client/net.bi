' Deadline bounded TCP and TLS streams.
'
' The POSIX socket and OpenSSL entry points are declared here against their
' documented C ABI rather than through a bundled FreeBASIC binding, so the
' client depends only on symbols the runtime image actually ships. Everything
' above the stream (HTTP framing, RFC 6455, the Convex sync protocol) is
' written in FreeBASIC.

#pragma once

#include once "core.bi"

const AF_INET = 2
const AF_UNSPEC = 0
const SOCK_STREAM = 1
const IPPROTO_TCP = 6
const SOL_SOCKET = 1
const SO_REUSEADDR = 2
const SO_ERROR = 4
const TCP_NODELAY = 1
const F_GETFL = 3
const F_SETFL = 4
const O_NONBLOCK = &o4000
const POLLIN = 1
const POLLOUT = 4
const SHUT_RDWR = 2
const EINPROGRESS = 115
const EAGAIN_ERRNO = 11
const EINTR_ERRNO = 4

type PollFdT
  fd as long
  events as short
  revents as short
end type

type SockAddrInT
  sin_family as ushort
  sin_port as ushort
  sin_addr as ulong
  sin_zero as zstring * 8
end type

' glibc's struct addrinfo on linux/amd64. NetSelfTest asserts the size so a
' layout drift fails a unit test instead of corrupting a connect call.
type AddrInfoT
  ai_flags as long
  ai_family as long
  ai_socktype as long
  ai_protocol as long
  ai_addrlen as ulong
  ai_addr as any ptr
  ai_canonname as zstring ptr
  ai_next as AddrInfoT ptr
end type

' A single stream abstraction so the HTTP and WebSocket layers share one
' bounded read/write path with identical deadline semantics.
type ConvexStream
  fd as long
  ssl as any ptr
  ctx as any ptr
  closed as boolean
end type

declare sub NetInitialize()
declare sub StreamReset(byref stream as ConvexStream)
declare function StreamConnect( _
  byref stream as ConvexStream, _
  byref host as string, _
  byval port as long, _
  byval useTls as boolean, _
  byval timeoutMs as long, _
  byref fault as ConvexFault) as boolean
' Returns the byte count, 0 when the deadline passed with no data, and -1 on a
' transport failure. A clean peer shutdown is reported as -2 so the caller can
' tell "closed" from "broken".
declare function StreamRead( _
  byref stream as ConvexStream, _
  byval buffer as ubyte ptr, _
  byval capacity as long, _
  byval deadline as longint, _
  byref reason as string) as long
declare function StreamWriteAll( _
  byref stream as ConvexStream, _
  byref payload as string, _
  byval deadline as longint, _
  byref reason as string) as boolean
declare sub StreamClose(byref stream as ConvexStream)
declare function StreamIsOpen(byref stream as ConvexStream) as boolean
declare function NetSelfTest(byref reason as string) as boolean

declare function ListenLoopback( _
  byref address as string, _
  byref fault as ConvexFault) as long
declare function AcceptOne( _
  byval listener as long, _
  byval timeoutMs as long, _
  byref fault as ConvexFault) as long
declare function PollDescriptor( _
  byval fd as long, _
  byval events as short, _
  byval timeoutMs as long) as long
declare function WriteAllFd( _
  byval fd as long, _
  byref payload as string, _
  byval deadline as longint, _
  byref reason as string) as boolean
' Bounded descriptor read: >0 is a byte count, 0 is a clean end of stream,
' -1 means retry, and -2 is a real error.
declare function ReadFd( _
  byval fd as long, _
  byval buffer as any ptr, _
  byval capacity as long) as long
declare function CloseFd(byval fd as long) as long
declare function MakeNonBlocking(byval fd as long) as boolean
