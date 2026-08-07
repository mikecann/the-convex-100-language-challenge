// The adapter's single-writer NDJSON output queue.
//
// Test-only infrastructure. One FIFO owns stdout or the controller socket, so
// the order events are accepted in is the order they reach the wire, and an
// acknowledgement can never overtake an event enqueued before it.
//
// The queue is bounded by both a count and a byte budget. A count alone is not
// a memory bound when one Convex value can approach the frame limit, and the
// in-flight line stays accounted for while a stopped reader blocks the write,
// so the bound also covers a writer parked inside the kernel.
#ifndef CONVEX_ADAPTER_OUTPUT_PIKE
#define CONVEX_ADAPTER_OUTPUT_PIKE

constant MAX_PENDING_EVENTS = 64;
constant MAX_PENDING_BYTES = 8 * 1024 * 1024;
constant ENTRY_OVERHEAD_BYTES = 256;
constant OUTPUT_DRAIN_TIMEOUT_MS = 5000;

int adapter_now_ms()
{
  return gethrtime() / 1000;
}

string encode_event_line(mapping event)
{
  return string_to_utf8(Standards.JSON.encode(event)) + "\n";
}

class OutputQueue
{
  object stream;
  array(string) lines = ({});
  array(int) costs = ({});
  int pending_bytes;
  int written_of_first;
  int failed;
  string failure_message = "";
  int max_events = MAX_PENDING_EVENTS;
  int max_bytes = MAX_PENDING_BYTES;

  protected void create(object output_stream, void|int event_limit,
                        void|int byte_limit)
  {
    stream = output_stream;
    if (event_limit)
      max_events = event_limit;
    if (byte_limit)
      max_bytes = byte_limit;
  }

  // Returns 1 when the event was accepted. Enqueue never waits for capacity:
  // the Live owner may be producing the very event that would unblock a
  // controller command, so backpressure becomes a bounded adapter failure
  // rather than a deadlock in either direction.
  int enqueue(mapping event)
  {
    if (failed)
      return 0;
    if (sizeof(lines) >= max_events) {
      fail("adapter output queue exceeded its event limit");
      return 0;
    }
    string line = encode_event_line(event);
    int cost = sizeof(line) + ENTRY_OVERHEAD_BYTES;
    if (pending_bytes + cost > max_bytes) {
      fail("adapter output queue exceeded its byte limit");
      return 0;
    }
    lines += ({ line });
    costs += ({ cost });
    pending_bytes += cost;
    flush();
    return !failed;
  }

  void fail(string message)
  {
    if (failed)
      return;
    failed = 1;
    failure_message = message;
    lines = ({});
    costs = ({});
    pending_bytes = 0;
    written_of_first = 0;
    // Closing the stalled stream wakes the peer's side of the conversation and
    // makes the failure observable instead of silently truncating the stream.
    if (stream)
      catch { stream->close(); };
  }

  void flush()
  {
    while (sizeof(lines) && !failed) {
      string remaining = lines[0][written_of_first..];
      int written;
      mixed error_value = catch { written = stream->write(remaining); };
      if (error_value) {
        fail("adapter output stream failed: " + describe_error(error_value));
        return;
      }
      if (written < 0) {
        fail("adapter output stream failed");
        return;
      }
      if (written < sizeof(remaining)) {
        // Keep the partially written line queued and accounted for. A reader
        // that stopped mid-line still counts against the bound.
        written_of_first += written;
        return;
      }
      pending_bytes -= costs[0];
      lines = lines[1..];
      costs = costs[1..];
      written_of_first = 0;
    }
  }

  int pending_events()
  {
    return sizeof(lines);
  }

  // Bounded shutdown flush. A controller that stopped reading must not be able
  // to hold the adapter open past this deadline.
  int drain(void|int timeout_ms)
  {
    int deadline = adapter_now_ms() + (timeout_ms || OUTPUT_DRAIN_TIMEOUT_MS);
    while (sizeof(lines) && !failed) {
      flush();
      if (!sizeof(lines) || failed)
        break;
      if (adapter_now_ms() >= deadline)
        return 0;
      Pike.DefaultBackend(0.01);
    }
    return !failed;
  }
}

#endif
