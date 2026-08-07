#!/usr/bin/env pike
// Test-only probe for the adapter's ADAPTER_LISTEN transport.
//
// The shared harness never speaks to the adapter over stdin: it connects to the
// listening container and carries the same NDJSON stream over TCP. This probe
// exercises that path locally, so a broken listener is found in `./run test`
// rather than halfway through a conformance run.

int fail(string message, mixed ... arguments)
{
  werror("FAIL adapter TCP transport: " + message + "\n", @arguments);
  return 1;
}

int main(int argc, array(string) argv)
{
  if (argc < 2) {
    werror("usage: tcp_probe.pike host:port\n");
    return 2;
  }
  string address = argv[1];
  int separator = -1;
  for (int index = sizeof(address) - 1; index >= 0; index--)
    if (address[index] == ':') {
      separator = index;
      break;
    }
  if (separator < 1)
    return fail("address %s is not host:port", address);
  string host = address[..separator - 1];
  int port = (int)address[separator + 1..];

  // The adapter may still be starting up, so retry for a bounded time.
  Stdio.File peer;
  int connected;
  for (int attempt = 0; attempt < 100 && !connected; attempt++) {
    peer = Stdio.File();
    if (peer->connect(host, port)) {
      connected = 1;
      break;
    }
    sleep(0.1);
  }
  if (!connected)
    return fail("could not reach the adapter at %s", address);

  peer->write("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"
              "{\"id\":\"close\",\"op\":\"close\"}\n");
  string received = peer->read();
  peer->close();
  if (!received)
    return fail("the adapter sent nothing");

  array(string) lines = (received / "\n") - ({ "" });
  if (sizeof(lines) != 2)
    return fail("expected exactly two events, got %d", sizeof(lines));

  mapping ready = Standards.JSON.decode(utf8_to_string(lines[0]));
  if (ready->type != "ready" || ready->id != "hello")
    return fail("the first event was not a ready acknowledgement");
  if (ready->protocolVersion != 1)
    return fail("the ready event did not report protocol version 1");
  if (ready->language != "pike")
    return fail("the ready event reported language %O", ready->language);
  if (!stringp(ready->implementation) || !sizeof(ready->implementation))
    return fail("the ready event omitted its implementation provenance");
  if (!stringp(ready->runtime) || !sizeof(ready->runtime))
    return fail("the ready event omitted its runtime version");

  mapping closed = Standards.JSON.decode(utf8_to_string(lines[1]));
  if (closed->type != "closed" || closed->id != "close")
    return fail("the adapter did not acknowledge a clean close");

  write("PASS adapter TCP transport (%s)\n", ready->runtime);
  return 0;
}
