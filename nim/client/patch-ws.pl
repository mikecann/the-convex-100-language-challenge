use strict;
use warnings;

my $path = shift @ARGV or die "usage: patch-ws.pl path\n";
open my $input, '<', $path or die "open $path: $!\n";
local $/;
my $source = <$input>;
close $input;

$source =~ s{import asyncdispatch, asynchttpserver, asyncnet, base64, httpclient, httpcore,\n\s*nativesockets, net, random, std/sha1, streams, strformat, strutils, uri\n}{import asyncdispatch, asynchttpserver, asyncnet, base64, httpclient, httpcore,\n    nativesockets, net, random, std/sha1, streams, strformat, strutils, times, uri\n\nconst\n  convexWebSocketPacketLimit = 2 * 1024 * 1024 + 64 * 1024\n  convexWebSocketFrameDeadlineMilliseconds = 5_000\n}
  or die "could not add WebSocket packet limit\n";

$source =~ s{(\s*client\.headers = newHttpHeaders\(\{.*?\n\s*\}\)\n)}{$1  client.headers["Convex-Client"] = "nim-0.2.0"\n}s
  or die "could not add Convex-Client header\n";

$source =~ s{  var res = await client\.get\(\$uri\)\n}{  let handshake = client.get(\$uri)\n  if not await handshake.withTimeout(5_000):\n    client.close()\n    raise newException(WebSocketHandshakeError, "WebSocket handshake timed out")\n  var res = await handshake\n}
  or die "could not add WebSocket handshake deadline\n";

$source =~ s{  if ws\.readyState != Open:\n    # Ignore calls to send on a closed socket\.\n    return\n}{  if ws.readyState != Open:\n    raise newWebSocketClosedError()\n}
  or die "could not make closed WebSocket sends fail\n";

$source =~ s{  except Defect, IOError, OSError, ValueError:\n    # Don't throw exceptions just close the socket\.\n    ws\.readyState = Closed\n}{  except CatchableError:\n    ws.readyState = Closed\n    raise newException(WebSocketError,\n      "WebSocket send failed: " & getCurrentExceptionMsg())\n}
  or die "could not make WebSocket write failures observable\n";

# asyncnet defaults to {SafeDisconn}, which completes a send to a reset peer
# without raising.  The re-raise above then never fires, and an Add the server
# never received looks acknowledged.  Drop the flag so writes are observable.
$source =~ s{      await ws\.tcpSocket\.send\(data\)\n}{      await ws.tcpSocket.send(data, flags = \{\})\n}
  or die "could not make disconnected WebSocket sends fail\n";

$source =~ s{    finalLen = cast\[ptr uint32\]\(length\[4\]\.addr\)\[\]\.htonl\n}{    # Decode all eight bytes. The upstream helper only inspected the low four,\n    # so a hostile 64-bit length could wrap to a small allocation.\n    if (uint8(length[0]) and 0x80) != 0:\n      ws.readyState = Closed\n      raise newException(WebSocketError, "invalid 64-bit WebSocket length")\n    for value in length:\n      finalLen = (finalLen shl 8) or uint(uint8(value))\n}
  or die "could not make 64-bit WebSocket lengths observable\n";

$source =~ s{  result\.rsv3 = b0\[3\]\n  result\.opcode = \(b0 and 0x0f\)\.Opcode\n}{  result.rsv3 = b0[3]\n  let rawOpcode = b0 and 0x0f\n  if rawOpcode notin [0'u8, 1'u8, 2'u8, 8'u8, 9'u8, 10'u8]:\n    ws.readyState = Closed\n    raise newException(WebSocketError, "reserved WebSocket opcode")\n  result.opcode = rawOpcode.Opcode\n}
  or die "could not add WebSocket opcode validation\n";

$source =~ s{  # Read the data\.\n}{  # Control frames may not be fragmented and are limited to 125 bytes.\n  if result.opcode in {Close, Ping, Pong} and (not result.fin or finalLen > 125):\n    ws.readyState = Closed\n    raise newException(WebSocketError, "invalid WebSocket control frame")\n\n  # Read the data.\n}
  or die "could not add WebSocket control-frame validation\n";

$source =~ s{  # Read the data\.\n  result\.data = await ws\.tcpSocket\.recv\(int finalLen\)\n}{  # Reject the declared frame size before allocating its payload. The caller\n  # passes the remaining aggregate allowance for data frames. Control frames\n  # have their independent RFC 6455 limit and do not consume it.\n  let frameLimit = if result.opcode in {Close, Ping, Pong}: 125 else: payloadLimit\n  if finalLen > uint(frameLimit):\n    ws.readyState = Closed\n    raise newException(WebSocketError, "WebSocket frame exceeds packet limit")\n\n  # Read the data.\n  result.data = await ws.tcpSocket.recv(int finalLen)\n}
  or die "could not add WebSocket frame size guard\n";

$source =~ s{proc recvFrame\(ws: WebSocket\): Future\[Frame\] \{\.async\.\} =}{type ConvexFrameRead = ref object\n  deadline: float\n\nproc convexRecvExact(ws: WebSocket; size: int; state: ConvexFrameRead;\n    idleAllowed = false): Future[string] {.async.} =\n  if size == 0:\n    return ""\n  if state.deadline == 0 and idleAllowed:\n    let first = await ws.tcpSocket.recv(1)\n    if first.len != 1:\n      ws.readyState = Closed\n      raise newWebSocketClosedError()\n    result.add(first)\n  if state.deadline == 0:\n    state.deadline = epochTime() +\n      convexWebSocketFrameDeadlineMilliseconds.float / 1_000.0\n  while result.len < size:\n    let remainingMilliseconds = int((state.deadline - epochTime()) * 1_000.0)\n    if remainingMilliseconds <= 0:\n      ws.readyState = Closed\n      ws.tcpSocket.close()\n      raise newException(WebSocketError, "WebSocket frame deadline exceeded")\n    let read = ws.tcpSocket.recv(size - result.len)\n    if not await read.withTimeout(remainingMilliseconds):\n      ws.readyState = Closed\n      ws.tcpSocket.close()\n      raise newException(WebSocketError, "WebSocket frame deadline exceeded")\n    let piece = await read\n    if piece.len == 0:\n      ws.readyState = Closed\n      raise newWebSocketClosedError()\n    result.add(piece)\n\nproc recvFrame(ws: WebSocket; payloadLimit = convexWebSocketPacketLimit;\n    idleAllowed = true; frameDeadline = 0.0): Future[Frame] {.async.} =\n  let convexRead = ConvexFrameRead(deadline: frameDeadline)}
  or die "could not add remaining-payload argument\n";

$source =~ s{header = await ws\.tcpSocket\.recv\(2\)}{header = await convexRecvExact(ws, 2, convexRead, idleAllowed)}
  or die "could not make the frame header exact\n";
$source =~ s{var length = await ws\.tcpSocket\.recv\(2\)}{var length = await convexRecvExact(ws, 2, convexRead)}
  or die "could not make the 16-bit length exact\n";
$source =~ s{var length = await ws\.tcpSocket\.recv\(8\)}{var length = await convexRecvExact(ws, 8, convexRead)}
  or die "could not make the 64-bit length exact\n";
$source =~ s{maskKey = await ws\.tcpSocket\.recv\(4\)}{maskKey = await convexRecvExact(ws, 4, convexRead)}
  or die "could not make the mask exact\n";
$source =~ s{result\.data = await ws\.tcpSocket\.recv\(int finalLen\)}{result.data = await convexRecvExact(ws, int(finalLen), convexRead)}
  or die "could not make the payload exact\n";

my $start = index($source, 'proc receivePacket*');
my $finish = index($source, 'proc receiveStrPacket*', $start);
die "could not locate receivePacket\n" if $start < 0 or $finish < 0;

my $replacement = <<'NIM';
proc receivePacket*(ws: WebSocket): Future[(Opcode, string)] {.async.} =
  ## Control frames may appear between fragmented data frames.  The original
  ## 0.6.0 helper treated those control frames as continuations, which closed
  ## an otherwise valid Convex connection during a ping or fragmented JSON
  ## transition.  Keep the frame state on this connection, answer Ping, and
  ## only finish after the original data message's final continuation.
  var firstOpcode = Cont
  var payload = ""
  var started = false
  var messageDeadline = 0.0
  while true:
    let remaining = convexWebSocketPacketLimit - payload.len
    let frame = await ws.recvFrame(remaining, not started, messageDeadline)
    case frame.opcode
    of Ping:
      await ws.send(frame.data, Pong)
      continue
    of Pong:
      continue
    of Close:
      ws.readyState = Closed
      raise newWebSocketClosedError()
    of Text, Binary:
      if started:
        raise newWebSocketClosedError()
      firstOpcode = frame.opcode
      payload = frame.data
      started = true
    of Cont:
      if not started:
        raise newWebSocketClosedError()
      if frame.data.len > convexWebSocketPacketLimit - payload.len:
        ws.readyState = Closed
        raise newException(WebSocketError,
          "fragmented WebSocket packet exceeds packet limit")
      payload.add(frame.data)
    if started and not frame.fin and messageDeadline == 0:
      messageDeadline = epochTime() +
        convexWebSocketFrameDeadlineMilliseconds.float / 1_000.0
    if started and frame.fin:
      return (firstOpcode, payload)

NIM

substr($source, $start, $finish - $start, $replacement);
open my $output, '>', $path or die "write $path: $!\n";
print {$output} $source;
close $output;
