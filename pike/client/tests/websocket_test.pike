#!/usr/bin/env pike
// RFC 6455 tests for the Pike WebSocket client.
//
// Every case runs over an in-process channel, so the upgrade validation,
// masking, fragment reassembly, control frames, and both bounded deadlines are
// asserted directly rather than inferred from a cooperative peer.
#include "../convex.pike"
#include "support.pike"

mapping ws_fixture()
{
  mapping observed = ([
    "opened": 0,
    "messages": ({}),
    "closed": 0,
    "reason": "",
  ]);
  FakeChannel channel = FakeChannel();
  observed->channel = channel;
  observed->connection = WebSocketConnection(
    channel, parse_url("ws://backend:3210/api/sync"), "pike-test",
    lambda() { observed->opened++; },
    lambda(string payload) { observed->messages += ({ payload }); },
    lambda(string reason) {
      observed->closed++;
      observed->reason = reason;
    });
  return observed;
}

mapping opened_fixture()
{
  mapping fixture = ws_fixture();
  FakeChannel channel = fixture->channel;
  channel->feed(handshake_response_for(channel->take_written()));
  return fixture;
}

void test_upgrade_request()
{
  mapping fixture = ws_fixture();
  string request = fixture->channel->take_written();
  ok(has_prefix(request, "GET /api/sync HTTP/1.1\r\n"),
     "the upgrade requests the sync endpoint");
  ok(search(request, "\r\nHost: backend:3210\r\n") > 0,
     "the upgrade carries the deployment authority");
  ok(search(request, "\r\nSec-WebSocket-Version: 13\r\n") > 0,
     "the upgrade pins RFC 6455 version 13");
  ok(search(request, "\r\nConvex-Client: pike-test\r\n") > 0,
     "the upgrade identifies this client");
  ok(search(request, "\r\nSec-WebSocket-Key: ") > 0,
     "the upgrade sends a nonce key");
}

void test_upgrade_validation()
{
  mapping mismatch = ws_fixture();
  mismatch->channel->take_written();
  mismatch->channel->feed("HTTP/1.1 101 Switching Protocols\r\n"
                          "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: not-the-right-value\r\n\r\n");
  check_equal(mismatch->opened, 0, "a wrong accept value never opens");
  check_equal(mismatch->closed, 1, "a wrong accept value retires the socket");

  mapping refused = ws_fixture();
  refused->channel->take_written();
  refused->channel->feed("HTTP/1.1 200 OK\r\n\r\n");
  check_equal(refused->closed, 1, "a non-101 answer retires the socket");

  mapping extended = ws_fixture();
  string request = extended->channel->take_written();
  string response = handshake_response_for(request);
  response = response[..sizeof(response) - 3] +
             "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n";
  extended->channel->feed(response);
  check_equal(extended->closed, 1,
              "an unnegotiated extension retires the socket");
}

void test_message_delivery()
{
  mapping fixture = opened_fixture();
  check_equal(fixture->opened, 1, "a valid 101 opens the connection");

  fixture->channel->feed(server_text("{\"type\":\"Ping\"}"));
  check_equal(fixture->messages, ({ "{\"type\":\"Ping\"}" }),
              "a whole text frame is delivered");

  // A four byte character split across two fragments. The reassembled payload
  // must be byte-identical, and no partial sequence may leak out early.
  string emoji = string_to_utf8(sprintf("%c", 0x1F7E8));
  string payload = "ab" + emoji + "cd";
  array(string) fragments = server_fragmented_text(payload, 3);
  fixture->channel->feed(fragments[0]);
  check_equal(sizeof(fixture->messages), 1,
              "an unfinished fragment delivers nothing");
  fixture->channel->feed(fragments[1]);
  check_equal(fixture->messages[1], payload,
              "fragmented UTF-8 is reassembled byte for byte");
}

void test_byte_at_a_time()
{
  mapping fixture = ws_fixture();
  string request = fixture->channel->take_written();
  string wire = handshake_response_for(request) +
                server_text("{\"type\":\"Ping\"}");
  fixture->channel->feed_byte_by_byte(wire);
  check_equal(fixture->opened, 1, "a handshake split byte by byte still opens");
  check_equal(fixture->messages, ({ "{\"type\":\"Ping\"}" }),
              "a frame split byte by byte is still delivered whole");
}

void test_client_frames_are_masked()
{
  mapping fixture = opened_fixture();
  fixture->channel->take_written();
  fixture->connection->send_text("{\"type\":\"Connect\"}");
  array(mapping) frames = parse_client_frames(fixture->channel->take_written());
  check_equal(sizeof(frames), 1, "one text frame is written");
  ok(frames[0]->masked, "RFC 6455 requires client frames to be masked");
  ok(frames[0]->fin, "a short message is a single final frame");
  check_equal(frames[0]->payload, "{\"type\":\"Connect\"}",
              "the unmasked payload is the original text");
}

void test_control_frames()
{
  mapping fixture = opened_fixture();
  fixture->channel->take_written();
  fixture->channel->feed(server_frame(WS_PING, "keepalive"));
  array(mapping) frames = parse_client_frames(fixture->channel->take_written());
  check_equal(sizeof(frames), 1, "a ping is answered");
  check_equal(frames[0]->opcode, WS_PONG, "the answer is a pong");
  check_equal(frames[0]->payload, "keepalive",
              "the pong echoes the ping payload");
  ok(frames[0]->masked, "the pong is masked like any client frame");
  check_equal(fixture->closed, 0, "a ping does not disturb the connection");

  fixture->channel->feed(server_frame(WS_PONG, "unsolicited"));
  check_equal(fixture->closed, 0, "an unsolicited pong is ignored");

  mapping peer_close = opened_fixture();
  peer_close->channel->take_written();
  peer_close->channel->feed(
    server_frame(WS_CLOSE, sprintf("%2c", 1001) + "bye"));
  check_equal(peer_close->closed, 1, "a close frame retires the connection");
  ok(search(peer_close->reason, "1001") > 0,
     "the peer's close code is reported");
  array(mapping) answer =
    parse_client_frames(peer_close->channel->take_written());
  check_equal(sizeof(answer), 1, "the close frame is answered before retiring");
  check_equal(answer[0]->opcode, WS_CLOSE, "the answer is a close frame");
}

void test_frame_rules()
{
  mapping masked = opened_fixture();
  // A server frame with the mask bit set is a protocol violation.
  masked->channel->feed(sprintf("%c%c", 0x81, 0x80) + "maskabcd");
  check_equal(masked->closed, 1,
              "a masked server frame retires the connection");

  mapping reserved = opened_fixture();
  reserved->channel->feed(sprintf("%c%c", 0xc1, 0x00));
  check_equal(reserved->closed, 1, "a reserved bit retires the connection");

  mapping oversized = opened_fixture();
  oversized->channel->feed(sprintf("%c%c%8c", 0x81, 127,
                                   MAX_WS_FRAME_BYTES + 1));
  check_equal(oversized->closed, 1,
              "a frame larger than the budget is refused before it is read");

  mapping control = opened_fixture();
  control->channel->feed(sprintf("%c%c%2c", 0x89, 126, 126) + ("x" * 126));
  check_equal(control->closed, 1, "an oversized control frame is refused");

  mapping fragmented_control = opened_fixture();
  fragmented_control->channel->feed(sprintf("%c%c", 0x09, 0));
  check_equal(fragmented_control->closed, 1,
              "a fragmented control frame is refused");

  mapping interleaved = opened_fixture();
  interleaved->channel->feed(sprintf("%c%c", 0x01, 1) + "a");
  interleaved->channel->feed(sprintf("%c%c", 0x81, 1) + "b");
  check_equal(interleaved->closed, 1,
              "a data frame inside a fragment sequence is refused");

  mapping binary = opened_fixture();
  binary->channel->feed(server_frame(WS_BINARY, "raw"));
  check_equal(binary->closed, 1, "Convex Live carries text frames only");
}

void test_partial_frame_deadline()
{
  mapping fixture = opened_fixture();
  int started = now_ms();
  // Half of a ten byte text frame. The parser must hold this exact state: it
  // may never rewind and resynchronise on a guessed frame boundary.
  fixture->channel->feed(sprintf("%c%c", 0x81, 10) + "12345");
  check_equal(fixture->closed, 0, "a half-arrived frame does not close early");
  fixture->connection->enforce_deadlines(started + PARTIAL_FRAME_TIMEOUT_MS -
                                         1);
  check_equal(fixture->closed, 0,
              "the partial frame deadline is not premature");

  fixture->channel->feed("67890");
  check_equal(fixture->messages, ({ "1234567890" }),
              "parser state survives across the gap");
  fixture->connection->enforce_deadlines(started + PARTIAL_FRAME_TIMEOUT_MS +
                                         1);
  check_equal(fixture->closed, 0,
              "a completed frame clears the partial deadline");

  mapping stalled = opened_fixture();
  int stall_started = now_ms();
  stalled->channel->feed(sprintf("%c%c", 0x81, 10) + "12345");
  stalled->connection->enforce_deadlines(stall_started +
                                         PARTIAL_FRAME_TIMEOUT_MS + 1);
  check_equal(stalled->closed, 1,
              "a frame stalled past the deadline abandons the connection");
  ok(!stalled->channel->is_open(),
     "abandoning the connection also closes the channel");
}

void test_bounded_close()
{
  mapping fixture = opened_fixture();
  fixture->channel->take_written();
  int started = now_ms();
  fixture->connection->begin_close(1000, "client closed");
  array(mapping) frames = parse_client_frames(fixture->channel->take_written());
  check_equal(sizeof(frames), 1, "a close frame is sent");
  check_equal(frames[0]->opcode, WS_CLOSE, "the frame is a close frame");
  check_equal(fixture->closed, 0, "the peer is given a chance to answer");
  ok(fixture->connection->close_deadline >=
       started + CLOSE_HANDSHAKE_TIMEOUT_MS,
     "the close is bounded by an explicit deadline");

  // The peer never answers. The deadline, not the peer, ends the connection.
  fixture->connection->enforce_deadlines(started + CLOSE_HANDSHAKE_TIMEOUT_MS +
                                         1);
  check_equal(fixture->closed, 1, "an unresponsive peer cannot delay close");

  mapping flooding = opened_fixture();
  int flood_started = now_ms();
  flooding->connection->begin_close(1000, "client closed");
  // A peer that keeps sending traffic must not extend the close either.
  for (int index = 0; index < 5; index++)
    flooding->channel->feed(server_text("{\"type\":\"Ping\"}"));
  flooding->connection->enforce_deadlines(flood_started +
                                          CLOSE_HANDSHAKE_TIMEOUT_MS + 1);
  check_equal(flooding->closed, 1, "a chattering peer cannot delay close");
  check_equal(sizeof(flooding->messages), 0,
              "messages after begin_close are not delivered");
}

void test_write_failure_retires()
{
  mapping fixture = opened_fixture();
  fixture->channel->refuse_writes = 1;
  fixture->connection->send_text("{\"type\":\"Connect\"}");
  check_equal(fixture->closed, 1, "a refused write retires the connection");
}

int main()
{
  test_upgrade_request();
  test_upgrade_validation();
  test_message_delivery();
  test_byte_at_a_time();
  test_client_frames_are_masked();
  test_control_frames();
  test_frame_rules();
  test_partial_frame_deadline();
  test_bounded_close();
  test_write_failure_retires();
  return finish("websocket framing");
}
