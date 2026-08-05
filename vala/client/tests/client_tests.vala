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

private static void subscriptions_suppress_duplicate_values () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (1, "demo:state", args);
  int deliveries = 0;
  subscription.updated.connect ((value, failure) => { deliveries++; });
  subscription.publish (number_node (1), null);
  subscription.publish (number_node (1), null);
  subscription.publish (number_node (2), null);
  assert (deliveries == 2);
}

int main (string[] args) {
  Test.init (ref args);
  Test.add_func ("/convex/timestamp/little-endian", timestamp_is_little_endian_uint64);
  Test.add_func ("/convex/timestamp/length", timestamp_requires_eight_bytes);
  Test.add_func ("/convex/subscription/deduplicate", subscriptions_suppress_duplicate_values);
  return Test.run ();
}
