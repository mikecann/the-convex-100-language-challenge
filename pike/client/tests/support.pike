// Shared fixtures for the language-local Pike tests.
//
// Included after ../convex.pike by every test program. Nothing here opens a
// socket: the client's only transport seam is the Channel interface, so a fake
// channel is enough to drive the HTTP reader, the RFC 6455 parser, and the
// whole Live state machine deterministically.
#ifndef CONVEX_TEST_SUPPORT_PIKE
#define CONVEX_TEST_SUPPORT_PIKE

int test_checks;
int test_failures;

void ok(int condition, string description)
{
  test_checks++;
  if (condition)
    return;
  test_failures++;
  werror("FAIL %s\n", description);
}

void check_equal(mixed got, mixed expected, string description)
{
  ok(equal(got, expected),
     sprintf("%s (got %O, expected %O)", description, got, expected));
}

// Assert that `body` throws a Convex failure of the given kind. The message is
// reported on mismatch so a wrong-but-plausible classification is visible.
void expect_error(function body, string kind, string description)
{
  mixed failed = catch { body(); };
  if (!failed) {
    test_checks++;
    test_failures++;
    werror("FAIL %s (no error was thrown)\n", description);
    return;
  }
  ConvexError failure = as_convex_error(failed);
  ok(failure->kind == kind,
     sprintf("%s (expected %s, got %s: %s)", description, kind, failure->kind,
             failure->message));
}

int finish(string suite)
{
  if (test_failures) {
    werror("%s: %d of %d checks failed\n", suite, test_failures, test_checks);
    return 1;
  }
  write("PASS %s (%d checks)\n", suite, test_checks);
  return 0;
}

// A Channel that never leaves the process. Tests push bytes in with feed() and
// read what the client produced with take_written().
class FakeChannel
{
  inherit Channel;

  string written = "";
  int ready = 1;
  int dead;
  int refuse_writes;
  string failure = "";

  int write(string data)
  {
    if (dead || refuse_writes)
      return 0;
    written += data;
    return 1;
  }

  void hard_close(string reason)
  {
    die(reason);
  }

  void die(string reason)
  {
    if (dead)
      return;
    dead = 1;
    ready = 0;
    failure = reason;
    if (close_handler)
      close_handler(reason);
  }

  int is_open()
  {
    return !dead;
  }

  int is_ready()
  {
    return ready && !dead;
  }

  int pending_output()
  {
    return 0;
  }

  string failure_reason()
  {
    return failure;
  }

  void feed(string data)
  {
    if (data_handler)
      data_handler(data);
  }

  // Deliver the bytes one at a time. Any parser that only works on tidy
  // network-sized pieces fails this immediately.
  void feed_byte_by_byte(string data)
  {
    foreach (data / "", string byte)
      feed(byte);
  }

  string take_written()
  {
    string collected = written;
    written = "";
    return collected;
  }
}

// An HttpTransport that answers from a script instead of a deployment.
class FakeHttpTransport
{
  inherit HttpTransport;

  array(HttpResponse) scripted = ({});
  array(mapping) requests = ({});
  int served;

  protected void create(array(HttpResponse) responses)
  {
    scripted = responses;
  }

  HttpResponse request(mapping target, string method, string path,
                       mapping(string:string) headers, string body,
                       int deadline_ms, void|string operation)
  {
    requests += ({ ([
      "target": target,
      "method": method,
      "path": path,
      "headers": headers,
      "body": body,
      "operation": operation,
    ]) });
    if (served >= sizeof(scripted))
      throw(transport_error("fake transport ran out of responses", operation));
    return scripted[served++];
  }
}

HttpResponse json_response(int status, string body)
{
  return HttpResponse(status, body,
                      ([ "content-type": "application/json" ]), "");
}

// Build the 101 a compliant server would return for this exact upgrade
// request, so the accept check is exercised for real rather than bypassed.
string handshake_response_for(string request)
{
  string marker = "Sec-WebSocket-Key: ";
  int start = search(request, marker);
  if (start < 0)
    error("upgrade request carried no Sec-WebSocket-Key\n");
  start += sizeof(marker);
  int end = search(request, "\r\n", start);
  string key = request[start..end - 1];
  return "HTTP/1.1 101 Switching Protocols\r\n"
         "Upgrade: websocket\r\n"
         "Connection: Upgrade\r\n"
         "Sec-WebSocket-Accept: " + websocket_accept_for(key) + "\r\n\r\n";
}

// Unmasked server frames, which is what RFC 6455 requires of a server.
string server_frame(int opcode, string payload)
{
  int length = sizeof(payload);
  string header = sprintf("%c", 0x80 | opcode);
  if (length < 126)
    header += sprintf("%c", length);
  else if (length < 65536)
    header += sprintf("%c%2c", 126, length);
  else
    header += sprintf("%c%8c", 127, length);
  return header + payload;
}

string server_text(string payload)
{
  return server_frame(WS_TEXT, payload);
}

// Split a text frame into two fragments so continuation handling and split
// UTF-8 sequences are covered.
array(string) server_fragmented_text(string payload, int split_at)
{
  string first = payload[..split_at - 1];
  string rest = payload[split_at..];
  return ({
    sprintf("%c%c", WS_TEXT, sizeof(first)) + first,
    sprintf("%c%c", 0x80 | WS_CONTINUATION, sizeof(rest)) + rest,
  });
}

// Decode what the client wrote, unmasking as a server would. Returns one
// mapping per frame with its opcode and payload.
array(mapping) parse_client_frames(string data)
{
  array(mapping) frames = ({});
  int cursor = 0;
  while (cursor + 2 <= sizeof(data)) {
    int first = data[cursor];
    int second = data[cursor + 1];
    int opcode = first & 0x0f;
    int length = second & 0x7f;
    int offset = cursor + 2;
    if (length == 126) {
      sscanf(data[offset..offset + 1], "%2c", length);
      offset += 2;
    } else if (length == 127) {
      sscanf(data[offset..offset + 7], "%8c", length);
      offset += 8;
    }
    string mask = "";
    if (second & 0x80) {
      mask = data[offset..offset + 3];
      offset += 4;
    }
    if (offset + length > sizeof(data))
      break;
    string payload = data[offset..offset + length - 1];
    if (sizeof(mask))
      payload = apply_mask(payload, mask);
    frames += ({ ([
      "opcode": opcode,
      "fin": (first & 0x80) != 0,
      "masked": (second & 0x80) != 0,
      "payload": payload,
    ]) });
    cursor = offset + length;
  }
  return frames;
}

array(mapping) client_messages(string data)
{
  array(mapping) messages = ({});
  foreach (parse_client_frames(data), mapping frame)
    if (frame->opcode == WS_TEXT)
      messages += ({ require_object(
        json_parse_bytes(frame->payload, "client frame", "test"),
        "client frame", "test") });
  return messages;
}

// A Live fixture: one owner wired to fake channels, plus the bookkeeping a test
// needs to answer handshakes and drive transitions.
class LiveFixture
{
  LiveOwner owner;
  array(FakeChannel) channels = ({});

  // The owner's channel factory. Every reconnect asks for a new one, so the
  // array doubles as the record of how many connections were attempted.
  Channel make_channel(mapping target)
  {
    FakeChannel channel = FakeChannel();
    channels += ({ channel });
    return channel;
  }

  protected void create(void|string url)
  {
    owner = LiveOwner(url || "https://example.convex.cloud", "pike-test",
                      make_channel);
  }

  int connection_attempts()
  {
    return sizeof(channels);
  }

  FakeChannel channel()
  {
    if (!sizeof(channels))
      error("no Live channel has been created yet\n");
    return channels[-1];
  }

  // Answer the upgrade request the client just wrote, completing the handshake.
  void accept_handshake()
  {
    FakeChannel current = channel();
    string request = current->take_written();
    current->feed(handshake_response_for(request));
  }

  void deliver(mapping message)
  {
    channel()->feed(server_text(json_bytes(message)));
  }

  array(mapping) sent()
  {
    return client_messages(channel()->take_written());
  }
}

// The Transition shape the pinned sync profile uses, spelled out so tests read
// as protocol documentation rather than as JSON soup.
mapping transition(mapping start, mapping end, array(mapping) modifications)
{
  return ([
    "type": "Transition",
    "startVersion": start,
    "endVersion": end,
    "modifications": modifications,
  ]);
}

mapping wire_version(int query_set, int identity, string timestamp)
{
  return ([ "querySet": query_set, "identity": identity, "ts": timestamp ]);
}

// Encode a little-endian uint64 the way Convex spells its timestamps.
string timestamp_for(int value)
{
  array(int) bytes = allocate(8);
  int remaining = value;
  for (int index = 0; index < 8; index++) {
    bytes[index] = remaining & 0xff;
    remaining >>= 8;
  }
  return MIME.encode_base64((string)bytes, 1);
}

#endif
