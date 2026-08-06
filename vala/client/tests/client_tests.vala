using GLib;
using Json;
using Convex;

/* These are small, Docker-run regression tests for protocol rules which do
 * not need a network peer. Real socket behaviour remains shared-harness work. */
private static void timestamp_is_little_endian_uint64 () {
  try {
    assert (Convex.timestamp_value ("AQAAAAAAAAA=") == 1);
    assert (Convex.timestamp_value ("AAAAAAAAAIA=") == (uint64) 0x8000000000000000);
  } catch (ClientError error) {
    assert_not_reached ();
  }
}

private static void timestamp_requires_eight_bytes () {
  bool rejected = false;
  try {
    Convex.timestamp_value ("AQ==");
  } catch (ClientError error) {
    rejected = true;
  }
  assert (rejected);
}

private static Json.Node number_node (int value) {
  var node = new Json.Node (NodeType.VALUE);
  node.set_int (value);
  return node;
}

private static void subscriptions_only_suppress_rehydration () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (1, "demo:state", args);
  int deliveries = 0;
  subscription.updated.connect ((value, failure) => { deliveries++; });
  subscription.publish (number_node (1), null);
  subscription.prepare_rehydration ();
  subscription.publish (number_node (1), null);
  subscription.publish (number_node (2), null);
  subscription.publish (number_node (2), null);
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  // The reconnect snapshot is suppressed once, but a later same-value
  // transition is real server work and must cross the relay.
  assert (deliveries == 3);
}


private static void uint32_numbers_are_strict () {
  var maximum = new Json.Node (NodeType.VALUE);
  maximum.set_double (4294967295.0);
  try {
    assert (Convex.uint32_number (maximum, "maximum") == uint.MAX);
  } catch (ClientError error) {
    assert_not_reached ();
  }

  double[] invalid_values = { -1.0, 4294967296.0, 1.5 };
  foreach (double invalid in invalid_values) {
    var node = new Json.Node (NodeType.VALUE);
    node.set_double (invalid);
    bool rejected = false;
    try {
      Convex.uint32_number (node, "invalid");
    } catch (ClientError error) {
      rejected = true;
    }
    assert (rejected);
  }

  var quoted = new Json.Node (NodeType.VALUE);
  quoted.set_string ("1");
  bool rejected_quoted = false;
  try {
    Convex.uint32_number (quoted, "quoted");
  } catch (ClientError error) {
    rejected_quoted = true;
  }
  assert (rejected_quoted);
}

private static void stopped_reader_budget_is_bounded () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (2, "demo:state", args);
  var builder = new StringBuilder ();
  for (int i = 0; i < 60000; i++) builder.append ("0123456789");
  var large = builder.str;
  for (int i = 0; i < 20; i++) {
    var value = new Json.Node (NodeType.VALUE);
    value.set_string (large);
    subscription.publish (value, null);
  }
  assert (subscription.pending_count () <= 16);
  assert (subscription.pending_byte_count () <= 8 * 1024 * 1024);
  subscription.invalidate ();
  assert (subscription.pending_count () == 0);
  assert (subscription.pending_byte_count () == 0);
}

private static void invalidation_is_a_delivery_barrier () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (3, "demo:state", args);
  int deliveries = 0;
  subscription.updated.connect ((value, failure) => { deliveries++; });
  var value = number_node (1);
  subscription.publish (value, null);
  subscription.invalidate ();
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  assert (deliveries == 0);
}

int main (string[] args) {
  Test.init (ref args);
  Test.add_func ("/convex/timestamp/little-endian", timestamp_is_little_endian_uint64);
  Test.add_func ("/convex/timestamp/length", timestamp_requires_eight_bytes);
  Test.add_func ("/convex/subscription/rehydration-suppression", subscriptions_only_suppress_rehydration);
  Test.add_func ("/convex/protocol/uint32-bounds", uint32_numbers_are_strict);
  Test.add_func ("/convex/live/stopped-reader-budget", stopped_reader_budget_is_bounded);
  Test.add_func ("/convex/live/invalidation-barrier", invalidation_is_a_delivery_barrier);
  return Test.run ();
}
