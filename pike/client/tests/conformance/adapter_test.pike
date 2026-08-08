#!/usr/bin/env pike
// Deterministic tests for the adapter's serialised event shapes and its bounded
// output queue.
//
// The shared controller validates every emitted line against
// _shared/schemas/adapter.schema.json and fails the whole run on the first
// mismatch. These assertions catch a wrong shape here, where the diagnosis is
// obvious, instead of inside a conformance transcript.
#include "events.pike"
#include "output.pike"

int checks;
int failures;

void ok(int condition, string description)
{
  checks++;
  if (condition)
    return;
  failures++;
  werror("FAIL %s\n", description);
}

void check_equal(mixed got, mixed expected, string description)
{
  ok(equal(got, expected),
     sprintf("%s (got %O, expected %O)", description, got, expected));
}

// A stream that can refuse or ration bytes, which is how a stopped or slow
// controller behaves.
class FakeStream
{
  string written = "";
  int accept_bytes = -1;
  int closed;

  int write(string data)
  {
    if (closed)
      return -1;
    int accepted = accept_bytes < 0 ? sizeof(data)
                                    : min(accept_bytes, sizeof(data));
    written += data[..accepted - 1];
    return accepted;
  }

  void close()
  {
    closed = 1;
  }
}

void test_event_shapes()
{
  check_equal(ready_event("h1", "pike", "native-pike-8.0", "Pike v8.0"),
              ([ "protocolVersion": 1, "id": "h1", "type": "ready",
                 "language": "pike", "implementation": "native-pike-8.0",
                 "runtime": "Pike v8.0" ]),
              "the ready event reports the protocol, language, and runtime");

  check_equal(ack_event("a1"), ([ "id": "a1", "type": "ack" ]),
              "an ack carries nothing but its id");
  check_equal(closed_event("c1"), ([ "id": "c1", "type": "closed" ]),
              "a closed event carries nothing but its id");

  check_equal(result_event("q1", ([ "count": 0 ]), ({})),
              ([ "id": "q1", "type": "result", "value": ([ "count": 0 ]) ]),
              "an empty log list is omitted rather than sent as []");
  check_equal(result_event("q2", 1, ({ "logged" })),
              ([ "id": "q2", "type": "result", "value": 1,
                 "logs": ({ "logged" }) ]),
              "log lines are published when Convex supplied them");

  mapping nulled = result_event("q3", Val.null, ({}));
  ok(!zero_type(nulled->value),
     "a null return value is still published as a value");

  check_equal(error_event("e1", failure_object("FunctionError", "boom", 1,
                                               ([ "code": "X" ])), ({})),
              ([ "type": "error", "id": "e1",
                 "error": ([ "name": "FunctionError", "message": "boom",
                             "data": ([ "code": "X" ]) ]) ]),
              "a structured error keeps its data payload");

  mapping anonymous = error_event(0, failure_object("ProtocolError", "bad", 0,
                                                    0));
  ok(zero_type(anonymous->id),
     "an error with no request id omits id instead of sending null");
  ok(zero_type(anonymous->error->data),
     "an error with no data omits data instead of sending null");

  mapping value_event = subscription_value_event("s1", ([ "count": 1 ]), ({}));
  check_equal(value_event,
              ([ "type": "subscription", "subscriptionId": "s1",
                 "value": ([ "count": 1 ]) ]),
              "a subscription value event names its subscription");
  ok(zero_type(value_event->error), "a value event carries no error key");

  mapping failed_event = subscription_error_event(
    "s1", failure_object("FunctionError", "denied", 0, 0), ({}));
  ok(zero_type(failed_event->value),
     "a failing subscription publishes no value alongside its error");
  check_equal(failed_event->error,
              ([ "name": "FunctionError", "message": "denied" ]),
              "the subscription error keeps its classification");
}

void test_line_encoding()
{
  string line = encode_event_line(([ "type": "ack", "id": "a" ]));
  ok(has_suffix(line, "\n"), "every event is one newline terminated line");
  check_equal(sizeof(line / "\n"), 2, "an event never spans two lines");
  mapping decoded = Standards.JSON.decode(utf8_to_string(line[..sizeof(line) -
                                                              2]));
  check_equal(decoded, ([ "type": "ack", "id": "a" ]),
              "the encoded line decodes back to the event");

  string wide = encode_event_line(([ "type": "ack", "id": "a",
                                     "value": sprintf("%c", 0x1F7E8) ]));
  mapping wide_decoded =
    Standards.JSON.decode(utf8_to_string(wide[..sizeof(wide) - 2]));
  check_equal(wide_decoded->value, sprintf("%c", 0x1F7E8),
              "astral characters survive the UTF-8 line encoding");
}

void test_output_ordering_and_partial_writes()
{
  FakeStream stream = FakeStream();
  OutputQueue queue = OutputQueue(stream);
  ok(queue->enqueue(ack_event("one")), "the first event is accepted");
  ok(queue->enqueue(ack_event("two")), "the second event is accepted");
  check_equal(queue->pending_events(), 0, "a willing reader drains the queue");
  array(string) lines = stream->written / "\n";
  check_equal(sizeof(lines), 3, "two events produced two lines");
  ok(search(lines[0], "\"one\"") > 0, "the first event was written first");
  ok(search(lines[1], "\"two\"") > 0, "the second event followed it");

  // A reader that only takes a few bytes at a time must not lose or duplicate
  // the line that was interrupted.
  FakeStream slow = FakeStream();
  slow->accept_bytes = 4;
  OutputQueue rationed = OutputQueue(slow);
  rationed->enqueue(ack_event("partial"));
  ok(rationed->pending_events() == 1,
     "an incompletely written line stays queued and accounted for");
  slow->accept_bytes = -1;
  rationed->flush();
  check_equal(rationed->pending_events(), 0, "the line finishes on resume");
  check_equal(slow->written, encode_event_line(ack_event("partial")),
              "the resumed line is written exactly once");
}

void test_output_bounds()
{
  FakeStream stopped = FakeStream();
  stopped->accept_bytes = 0;
  OutputQueue counted = OutputQueue(stopped, 4, 8 * 1024 * 1024);
  for (int index = 0; index < 4; index++)
    ok(counted->enqueue(ack_event("e" + index)),
       sprintf("event %d fits inside the count bound", index));
  ok(!counted->enqueue(ack_event("overflow")),
     "the event past the count bound is refused");
  ok(counted->failed, "exceeding the count bound fails the adapter closed");
  ok(search(counted->failure_message, "event limit") >= 0,
     "the failure names the bound that was exceeded");
  ok(stopped->closed,
     "the stalled stream is closed so the peer cannot wait forever");

  FakeStream byte_stopped = FakeStream();
  byte_stopped->accept_bytes = 0;
  // One accepted ack plus its overhead allowance, so the second must not fit.
  int one_event = sizeof(encode_event_line(ack_event("e0"))) +
                  ENTRY_OVERHEAD_BYTES;
  OutputQueue budgeted = OutputQueue(byte_stopped, 64, one_event);
  ok(budgeted->enqueue(ack_event("e0")),
     "the first event fits the byte budget");
  ok(!budgeted->enqueue(ack_event("e1")),
     "the event past the byte budget is refused");
  ok(search(budgeted->failure_message, "byte limit") >= 0,
     "the byte bound is reported distinctly from the count bound");
}

void test_drain_is_bounded()
{
  FakeStream stopped = FakeStream();
  stopped->accept_bytes = 0;
  OutputQueue queue = OutputQueue(stopped);
  queue->enqueue(ack_event("pending"));
  int started = adapter_now_ms();
  int drained = queue->drain(200);
  int elapsed = adapter_now_ms() - started;
  ok(!drained, "a stopped reader cannot be drained");
  ok(elapsed < 3000,
     sprintf("the shutdown flush is bounded by its deadline (%d ms)", elapsed));
  ok(queue->pending_events() == 1,
     "the undelivered line is still accounted for after the deadline");
}

int main()
{
  test_event_shapes();
  test_line_encoding();
  test_output_ordering_and_partial_writes();
  test_output_bounds();
  test_drain_is_bounded();
  if (failures) {
    werror("adapter events and output: %d of %d checks failed\n", failures,
           checks);
    return 1;
  }
  write("PASS adapter events and output (%d checks)\n", checks);
  return 0;
}
