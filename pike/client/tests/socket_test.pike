#!/usr/bin/env pike
// Tests for the real socket channel.
//
// Every other test in this directory drives the client through an in-process
// fake channel, which is what makes the protocol layers deterministic. These
// cases cover the part a fake cannot: a genuine descriptor deciding when the
// channel is ready, when the write callback is armed, and how a refused or
// dropped connection is announced. Everything runs over loopback, so there is
// no deployment, no name resolution, and no TLS involved.
#include "../convex.pike"
#include "support.pike"

// A loopback peer. It answers on an ephemeral port and records what the client
// sent, so the assertions below are about observed bytes rather than about the
// channel agreeing with itself.
class LoopbackServer
{
  Stdio.Port listener;
  int bound_port;
  Stdio.File peer;
  string received = "";

  protected void create()
  {
    listener = Stdio.Port();
    // Port 0 asks the kernel for a free port. The fixed candidates after it
    // exist only so these tests cannot fail on that spelling alone, the same
    // way the Docker stage pins a port for its adapter probe.
    foreach (({ 0, 18901, 18902, 18903, 18904 }), int candidate)
      if (listener->bind(candidate, on_accept, "127.0.0.1")) {
        bound_port = candidate ||
                     (int)((listener->query_address() / " ")[-1]);
        break;
      }
    if (!bound_port)
      error("could not bind a loopback port for the socket tests\n");
  }

  void on_accept(mixed id)
  {
    Stdio.File accepted = listener->accept();
    if (!accepted)
      return;
    peer = accepted;
    // No write callback: this fixture only ever sends small payloads, and an
    // armed one would spin the same backend the assertions are pumping.
    peer->set_nonblocking(on_data, 0, on_close);
  }

  void on_data(mixed id, string data)
  {
    received += data;
  }

  void on_close(mixed id)
  {
    drop();
  }

  void send(string data)
  {
    if (peer)
      peer->write(data);
  }

  void drop()
  {
    if (!peer)
      return;
    Stdio.File closing = peer;
    peer = 0;
    catch { closing->close(); };
  }

  void shutdown()
  {
    drop();
    if (!listener)
      return;
    Stdio.Port closing = listener;
    listener = 0;
    catch { closing->close(); };
  }
}

void test_readiness_and_write_arming()
{
  LoopbackServer server = LoopbackServer();
  mapping observed = ([ "data": "", "closed": 0, "reason": "" ]);
  SocketChannel channel = SocketChannel("127.0.0.1", server->bound_port, 0);
  channel->set_handlers(
    lambda(string bytes) { observed->data += bytes; },
    lambda(string reason) {
      observed->closed++;
      observed->reason = reason;
    });

  ok(!channel->is_ready(),
     "a channel is not ready before the peer can take bytes");
  ok(channel->write("hello\n"),
     "bytes queued before readiness are accepted, not refused");

  ok(pump_until(lambda() { return channel->is_ready(); }, deadline_in(5000)),
     "the channel reports ready once the connection can carry bytes");
  ok(pump_until(lambda() { return server->received == "hello\n"; },
                deadline_in(5000)),
     "the bytes queued before readiness reach the peer afterwards");
  check_equal(channel->pending_output(), 0,
              "nothing is left in the outgoing buffer");
  // An always-armed write callback fires on every backend pass while the
  // socket is writable. On the CPU-limited conformance container that would
  // spin for the life of the process, so an idle channel must disarm it.
  check_equal(channel->write_armed, 0,
              "the write callback is disarmed once the buffer drains");

  server->send("world\n");
  ok(pump_until(lambda() { return observed->data == "world\n"; },
                deadline_in(5000)),
     "inbound bytes reach the data handler");

  server->drop();
  ok(pump_until(lambda() { return observed->closed; }, deadline_in(5000)),
     "the peer going away is announced");
  check_equal(observed->closed, 1, "a close is announced exactly once");
  ok(!channel->is_open(), "the channel is closed after the peer went away");
  ok(!channel->is_ready(), "a closed channel is never ready");
  ok(!channel->write("late\n"), "a closed channel refuses further writes");
  server->shutdown();
}

void test_refusal_reaches_a_late_handler()
{
  // Port 1 is reserved and nothing in the test image listens on it, so this is
  // a refusal rather than a timeout.
  mapping observed = ([ "closed": 0, "reason": "" ]);
  SocketChannel channel = SocketChannel("127.0.0.1", 1, 0);
  // The Live owner can only attach its handlers once the channel object
  // exists, so a connect that already failed inside the constructor must still
  // be reported to whoever installs a close handler afterwards.
  channel->set_handlers(0,
                        lambda(string reason) {
                          observed->closed++;
                          observed->reason = reason;
                        });
  ok(pump_until(lambda() { return !channel->is_open(); }, deadline_in(5000)),
     "a refused connection closes the channel");
  check_equal(observed->closed, 1,
              "the refusal reaches a handler installed after construction");
  ok(sizeof(observed->reason) > 0, "the refusal carries a reason to report");
  check_equal(observed->reason, channel->failure_reason(),
              "the announced reason is the channel's recorded failure");
}

void test_close_before_handlers_is_not_lost()
{
  LoopbackServer server = LoopbackServer();
  SocketChannel channel = SocketChannel("127.0.0.1", server->bound_port, 0);
  // Retire it while nothing is listening to it. That is exactly the window the
  // Live owner sits in between asking for a channel and attaching to it, and a
  // close announced into that gap used to disappear.
  channel->hard_close("dropped before anyone was listening");

  mapping observed = ([ "closed": 0, "reason": "" ]);
  channel->set_handlers(0,
                        lambda(string reason) {
                          observed->closed++;
                          observed->reason = reason;
                        });
  check_equal(observed->closed, 1,
              "a close from before the handlers existed is still announced");
  check_equal(observed->reason, "dropped before anyone was listening",
              "the original reason survives the hand-over");

  channel->set_handlers(0,
                        lambda(string reason) { observed->closed++; });
  check_equal(observed->closed, 1,
              "the pending close is announced once, not to every handler");
  server->shutdown();
}

void test_connect_channel_waits_for_readiness()
{
  LoopbackServer server = LoopbackServer();
  mapping target = ([ "host": "127.0.0.1", "port": server->bound_port,
                      "tls": 0 ]);
  Channel channel = connect_channel(target, deadline_in(5000), "test");
  ok(channel->is_ready(),
     "connect_channel only returns a channel that can carry bytes");
  channel->hard_close("test finished");
  ok(!channel->is_open(), "hard_close retires the channel immediately");
  server->shutdown();
}

void test_tls_stream_api_is_present()
{
  // The TLS path itself needs a real deployment, but the SSL.File members it
  // depends on can be checked here. Pike spells parts of that API differently
  // across releases, and finding a missing one now is the difference between a
  // failed build and a failed hosted verification.
  array(string) members = tls_stream_members();
  foreach (({ "connect", "set_nonblocking", "set_write_callback", "write",
              "close" }), string needed)
    ok(search(members, needed) >= 0,
       sprintf("SSL.File exposes %s, which the socket channel calls", needed));
}

void test_expired_deadline_never_waits()
{
  LoopbackServer server = LoopbackServer();
  mapping target = ([ "host": "127.0.0.1", "port": server->bound_port,
                      "tls": 0 ]);
  // The deadline is absolute, so a budget that is already spent has to fail
  // here rather than granting one more connect's worth of time.
  int started = now_ms();
  expect_error(lambda() { connect_channel(target, now_ms() - 1, "test"); },
               TRANSPORT_ERROR, "an expired deadline refuses to connect");
  ok(now_ms() - started < 2000,
     "an expired deadline returns without waiting for the peer");
  server->shutdown();
}

int main()
{
  test_readiness_and_write_arming();
  test_refusal_reaches_a_late_handler();
  test_close_before_handlers_is_not_lost();
  test_connect_channel_waits_for_readiness();
  test_tls_stream_api_is_present();
  test_expired_deadline_never_waits();
  return finish("socket channel");
}
