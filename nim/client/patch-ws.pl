use strict;
use warnings;

my $path = shift @ARGV or die "usage: patch-ws.pl path\n";
open my $input, '<', $path or die "open $path: $!\n";
local $/;
my $source = <$input>;
close $input;

$source =~ s{(\s*client\.headers = newHttpHeaders\(\{.*?\n\s*\}\)\n)}{$1  client.headers["Convex-Client"] = "nim-0.2.0"\n}s
  or die "could not add Convex-Client header\n";

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
  while true:
    let frame = await ws.recvFrame()
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
      payload.add(frame.data)
    if started and frame.fin:
      return (firstOpcode, payload)

NIM

substr($source, $start, $finish - $start, $replacement);
open my $output, '>', $path or die "write $path: $!\n";
print {$output} $source;
close $output;
