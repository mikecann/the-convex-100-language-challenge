using GLib;
using Gee;
using Json;

private static void require_adapter_event (ArrayList<string> events, string id, string type) throws Error {
  assert (events.size > 0);
  var node = Convex.parse_json (events.get (events.size - 1));
  var object = node.get_object ();
  assert (object.get_string_member ("id") == id);
  assert (object.get_string_member ("type") == type);
}

private static uint adapter_subscription_values (ArrayList<string> events) {
  uint count = 0;
  foreach (var event in events) {
    try {
      var node = Convex.parse_json (event);
      var object = node.get_object ();
      if (object.get_string_member ("type") == "subscription" && object.has_member ("value")) count++;
    } catch (Error error) {
      stderr.printf ("adapter emitted invalid NDJSON: %s\n", error.message);
      assert_not_reached ();
    }
  }
  return count;
}

private static string repeated_text (string text, int count) {
  var result = new StringBuilder ();
  for (int index = 0; index < count; index++) result.append (text);
  return result.str;
}

private static void adapter_output_deadline_is_absolute () {
  int[] descriptors = new int[2];
  assert (Posix.pipe (descriptors) == 0);
  var output = new UnixOutputStream (descriptors[1], true);
  var pollable = output as PollableOutputStream;
  assert (pollable != null && pollable.can_poll ());
  uint8[] block = new uint8[4096];
  try {
    // Fill the pipe without a reader so the adapter's next event must take
    // the same nonblocking deadline path as a stopped TCP controller.
    for (;;) pollable.write_nonblocking (block, null);
  } catch (IOError error) {
    assert (error is IOError.WOULD_BLOCK);
  } catch (Error error) {
    stderr.printf ("could not prepare stopped adapter output: %s\n", error.message);
    assert_not_reached ();
  }

  Environment.set_variable ("ADAPTER_OUTPUT_DEADLINE_MS", "50", true);
  var adapter = new Adapter (new MainLoop ());
  adapter.set_output_for_test (output);
  int64 started = get_monotonic_time ();
  adapter.handle ("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}");
  int64 elapsed = get_monotonic_time () - started;
  assert (adapter.failed_for_process ());
  assert (adapter.output_in_flight_count_for_test () == 0);
  assert (adapter.output_in_flight_bytes_for_test () == 0);
  assert (elapsed >= 40 * TimeSpan.MILLISECOND);
  assert (elapsed < 500 * TimeSpan.MILLISECOND);
  Environment.unset_variable ("ADAPTER_OUTPUT_DEADLINE_MS");
  Posix.close (descriptors[0]);
}

private static void adapter_commands_enforce_the_exact_schema () {
  try {
    Environment.set_variable ("CONVEX_URL", "http://127.0.0.1:1", true);
    var adapter = new Adapter (new MainLoop ());
    var events = new ArrayList<string> ();
    adapter.emitted_for_test.connect ((event) => { events.add (event); });

    string maximum_id = repeated_text ("😀", 128);
    adapter.handle ("{\"protocolVersion\":1,\"id\":" + Convex.json_string (maximum_id) + ",\"op\":\"hello\"}");
    var maximum_event = Convex.parse_json (events.get (events.size - 1)).get_object ();
    assert (maximum_event.get_string_member ("type") == "ready");
    assert (maximum_event.get_string_member ("id") == maximum_id);

    string oversized_id = repeated_text ("😀", 129);
    adapter.handle ("{\"protocolVersion\":1,\"id\":" + Convex.json_string (oversized_id) + ",\"op\":\"hello\"}");
    var oversized_event = Convex.parse_json (events.get (events.size - 1)).get_object ();
    assert (oversized_event.get_string_member ("type") == "error");
    assert (!oversized_event.has_member ("id"));

    adapter.handle ("{\"id\":7,\"op\":\"close\"}");
    var typed_event = Convex.parse_json (events.get (events.size - 1)).get_object ();
    assert (typed_event.get_string_member ("type") == "error");
    assert (!typed_event.has_member ("id"));

    adapter.handle ("{\"id\":\"extra\",\"op\":\"close\",\"unexpected\":true}");
    var extra_event = Convex.parse_json (events.get (events.size - 1)).get_object ();
    assert (extra_event.get_string_member ("type") == "error");
    assert (!extra_event.has_member ("id"));

    // Tokens have no schema maxLength. Do not accidentally apply the ID's
    // 128-code-point limit to an unrelated string field.
    adapter.handle ("{\"id\":\"auth\",\"op\":\"setAuth\",\"token\":" +
                    Convex.json_string (repeated_text ("t", 512)) + "}");
    require_adapter_event (events, "auth", "ack");
  } catch (Error error) {
    stderr.printf ("strict adapter command test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

private static void adapter_debug_disconnect_replays_add_after_ack () {
  try {
    var peer = new RawPeer (0);
    peer.start ();
    Environment.set_variable ("CONVEX_URL", "http://127.0.0.1:" + peer.port.to_string (), true);
    var loop = new MainLoop ();
    var adapter = new Adapter (loop);
    var events = new ArrayList<string> ();
    adapter.emitted_for_test.connect ((event) => {
      assert (adapter.output_in_flight_count_for_test () == 1);
      assert (adapter.output_in_flight_bytes_for_test () >= event.length + 1 + 256);
      events.add (event);
    });
    adapter.handle ("{\"id\":\"subscribe\",\"op\":\"subscribe\",\"subscriptionId\":\"counter\",\"path\":\"demo:state\",\"args\":{\"room\":\"adapter-raw\"}}");
    require_adapter_event (events, "subscribe", "ack");
    spin_until (() => adapter_subscription_values (events) >= 2, 5 * 1000 * 1000, "adapter initial value and QueryFailed recovery");
    for (int index = 0; index < 5; index++) {
      uint previous_values = adapter_subscription_values (events);
      adapter.handle ("{\"id\":\"disconnect-" + index.to_string () + "\",\"op\":\"debugDisconnect\"}");
      require_adapter_event (events, "disconnect-" + index.to_string (), "ack");
      // The acknowledgement is emitted only after the old socket is retired
      // and the replacement connection is scheduled. The raw peer checks the
      // new Connect/Add before this wait can complete.
      spin_until (() => peer.connections >= (uint) index + 2, 5 * 1000 * 1000, "adapter reconnect Add replay");
      spin_until (() => adapter_subscription_values (events) == previous_values + 1, 5 * 1000 * 1000, "adapter changed reconnect value");
    }
    assert (peer.connections == 6);
    assert (peer.adds == 6);
    adapter.handle ("{\"id\":\"close\",\"op\":\"close\"}");
    require_adapter_event (events, "close", "closed");
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("adapter raw peer test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

private static void adapter_same_id_replacement_is_a_dequeue_barrier () {
  try {
    var peer = new RawPeer (5);
    peer.start ();
    Environment.set_variable ("CONVEX_URL", "http://127.0.0.1:" + peer.port.to_string (), true);
    var adapter = new Adapter (new MainLoop ());
    var events = new ArrayList<string> ();
    adapter.emitted_for_test.connect ((event) => {
      assert (adapter.output_in_flight_count_for_test () == 1);
      assert (adapter.output_in_flight_bytes_for_test () >= event.length + 1 + 256);
      events.add (event);
    });
    adapter.handle ("{\"id\":\"old\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{\"room\":\"old\"}}");
    require_adapter_event (events, "old", "ack");
    bool replaced = false;
    Convex.Subscription.before_delivery_for_test = (subscription) => {
      if (replaced) return;
      replaced = true;
      // This runs after the old relay dequeues its value but before the
      // callback could write it. The adapter must replace it atomically.
      adapter.handle ("{\"id\":\"replacement\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{\"room\":\"new\"}}");
    };
    spin_until (() => replaced, 5 * 1000 * 1000, "replacement dequeue hook");
    require_adapter_event (events, "replacement", "ack");
    spin_until (() => adapter_subscription_values (events) == 1, 5 * 1000 * 1000, "replacement subscription value");
    var subscription_event = Convex.parse_json (events.get (events.size - 1)).get_object ();
    assert (subscription_event.get_object_member ("value").get_int_member ("count") == 20);
    adapter.handle ("{\"id\":\"close\",\"op\":\"close\"}");
    require_adapter_event (events, "close", "closed");
    peer.stop ();
    Convex.Subscription.before_delivery_for_test = null;
  } catch (Error error) {
    Convex.Subscription.before_delivery_for_test = null;
    stderr.printf ("adapter replacement barrier test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

int main (string[] args) {
  Test.init (ref args);
  Test.add_func ("/convex/adapter/output/absolute-deadline", adapter_output_deadline_is_absolute);
  Test.add_func ("/convex/adapter/schema/strict-commands", adapter_commands_enforce_the_exact_schema);
  Test.add_func ("/convex/adapter/live/raw-peer/debug-disconnect-ack", adapter_debug_disconnect_replays_add_after_ack);
  Test.add_func ("/convex/adapter/live/raw-peer/same-id-dequeue-barrier", adapter_same_id_replacement_is_a_dequeue_barrier);
  return Test.run ();
}
