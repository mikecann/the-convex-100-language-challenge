use strict;
use warnings;

my $path = shift @ARGV or die "usage: patch-httpclient.pl path\n";
open my $input, '<', $path or die "open $path: $!\n";
local $/;
my $source = <$input>;
close $input;

# Nim's FutureStream is intentionally unbounded. Enforce the Convex response
# ceiling inside the standard HTTP parser, before fixed, chunked, or
# connection-close bytes enter that queue.
$source =~ s{(export httpcore except parseHeader[^\n]*\n)}{$1\nconst\n  convexHttpResponseLimit = 2 * 1024 * 1024\n  convexHttpHeaderLimit = 64 * 1024\n}
  or die "could not add Convex HTTP limits\n";

$source =~ s{(    if chunkSize <= 0:\n)}{    if chunkSize > convexHttpResponseLimit - client.contentProgress:\n      client.close()\n      httpError("HTTP response exceeds Convex byte limit")\n$1}
  or die "could not bound chunked bodies\n";

$source =~ s{    var chunkSizeStr = await client\.socket\.recvLine\(\)\n}{    var chunkSizeStr = await client.socket.recvLine(maxLength = 64)\n}
  or die "could not bound chunk headers\n";

# Reject before shifting, so a malicious hexadecimal length cannot wrap Nim's
# signed int and evade the aggregate body check below.
for my $digit_range (qw{0-9 a-f A-F}) {
  my $needle = $digit_range eq '0-9'
    ? q{        chunkSize = chunkSize shl 4 or (ord(chunkSizeStr[i]) - ord('0'))}
    : $digit_range eq 'a-f'
      ? q{        chunkSize = chunkSize shl 4 or (ord(chunkSizeStr[i]) - ord('a') + 10)}
      : q{        chunkSize = chunkSize shl 4 or (ord(chunkSizeStr[i]) - ord('A') + 10)};
  my $replacement = qq{        if chunkSize > convexHttpResponseLimit shr 4:\n          client.close()\n          httpError("HTTP response exceeds Convex byte limit")\n$needle};
  index($source, $needle) >= 0 or die "could not guard HTTP chunk integer overflow\n";
  $source =~ s{\Q$needle\E}{$replacement};
}

$source =~ s{(      client\.contentTotal = length\n)}{$1      if length < 0 or length > convexHttpResponseLimit:\n        client.close()\n        httpError("HTTP response exceeds Convex byte limit")\n}
  or die "could not bound fixed bodies\n";

$source =~ s{        while true:\n          let recvLen = await client\.recvFull\(4000, client\.timeout, true\)\n          if recvLen != 4000:\n            client\.close\(\)\n            break\n}{        while true:\n          # Read one byte past the allowance to distinguish an exact-limit EOF\n          # from a dishonest close-delimited response without a large allocation.\n          let allowance = convexHttpResponseLimit - client.contentProgress\n          let requested = min(4000, allowance + 1)\n          let recvLen = await client.recvFull(requested, client.timeout, true)\n          if client.contentProgress > convexHttpResponseLimit:\n            client.close()\n            httpError("HTTP response exceeds Convex byte limit")\n          if recvLen != requested:\n            client.close()\n            break\n}
  or die "could not bound close-delimited bodies\n";

$source =~ s{(  result\.headers = newHttpHeaders\(\)\n)}{$1  var convexHeaderBytes = 0\n}
  or die "could not initialise header accounting\n";

$source =~ s{(      line = await client\.socket\.recvLine\(\)\n)}{      line = await client.socket.recvLine(maxLength = convexHttpHeaderLimit)\n}
  or die "could not bound async header lines\n";

$source =~ s{(      line = client\.socket\.recvLine\(client\.timeout\)\n)}{      line = client.socket.recvLine(client.timeout,\n        maxLength = convexHttpHeaderLimit)\n}
  or die "could not bound sync header lines\n";

$source =~ s{(    if line == "":\n)}{    convexHeaderBytes += line.len\n    if convexHeaderBytes > convexHttpHeaderLimit:\n      client.close()\n      httpError("HTTP response headers exceed Convex byte limit")\n$1}
  or die "could not account response headers\n";

open my $output, '>', $path or die "write $path: $!\n";
print {$output} $source;
close $output;
