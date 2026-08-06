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

private static void adapter_debug_disconnect_replays_add_after_ack () {
  try {
    var peer = new RawPeer (0);
    peer.start ();
    Environment.set_variable ("CONVEX_URL", "http://127.0.0.1:" + peer.port.to_string (), true);
    var loop = new MainLoop ();
    var adapter = new Adapter (loop);
    var events = new ArrayList<string> ();
    adapter.emitted_for_test.connect ((event) => { events.add (event); });
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
    adapter.emitted_for_test.connect ((event) => { events.add (event); });
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
  Test.add_func ("/convex/adapter/live/raw-peer/debug-disconnect-ack", adapter_debug_disconnect_replays_add_after_ack);
  Test.add_func ("/convex/adapter/live/raw-peer/same-id-dequeue-barrier", adapter_same_id_replacement_is_a_dequeue_barrier);
  return Test.run ();
}
