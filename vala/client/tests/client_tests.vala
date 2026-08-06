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

// A dense array is the shape that separates wire size from retained size: it
// serializes to two bytes per element and retains a whole JsonNode for each.
private static Json.Node dense_array_node (int elements) {
  var array = new Json.Array.sized ((uint) elements);
  for (int index = 0; index < elements; index++) array.add_int_element (0);
  var node = new Json.Node (NodeType.ARRAY);
  node.set_array (array);
  return node;
}

private static Json.Node object_args () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  return args;
}

private static void drain_main_context () {
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
}

private static void json_documents_without_a_value_are_protocol_errors () {
  // JSON-GLib accepts these and leaves its root NULL. Copying that node raises
  // a critical, and json_node_get_node_type(NULL) reports JSON_NODE_OBJECT, so
  // a downstream type guard cannot catch it either.
  string[] valueless = { "", " ", "\n", "\t\r\n " };
  foreach (var document in valueless) {
    bool rejected = false;
    try {
      Convex.parse_json (document, "fixture");
    } catch (Error error) {
      rejected = error is ClientError.PROTOCOL;
    }
    assert (rejected);
  }
  try {
    assert (Convex.parse_json ("{\"ok\":true}", "fixture").get_node_type () == NodeType.OBJECT);
  } catch (Error error) {
    assert_not_reached ();
  }
}

private static bool budget_rejects (string document) {
  try {
    Convex.check_json_budget (document, "fixture");
  } catch (ClientError error) {
    return true;
  }
  return false;
}

private static void json_budget_bounds_the_tree_before_it_is_parsed () {
  var dense = new StringBuilder ();
  dense.append_c ('[');
  for (int index = 0; index < 200000; index++) dense.append (index == 0 ? "0" : ",0");
  dense.append_c (']');
  // Roughly 400 KB on the wire, well inside the 2 MiB frame cap, but over 25
  // MiB of retained JsonNodes. The parser must never be handed this.
  assert (budget_rejects (dense.str));

  var long_string = new StringBuilder ();
  long_string.append_c ('"');
  for (int index = 0; index < 200000; index++) long_string.append (",:[{");
  long_string.append_c ('"');
  // The same separator bytes inside a string are literal text on one node, so
  // the scanner must not charge them as structure.
  assert (!budget_rejects (long_string.str));

  var escaped = new StringBuilder ();
  escaped.append ("{\"k\":\"");
  for (int index = 0; index < 200000; index++) escaped.append ("\\\",");
  escaped.append ("\"}");
  assert (!budget_rejects (escaped.str));

  var deep = new StringBuilder ();
  for (int index = 0; index < 128; index++) deep.append_c ('[');
  for (int index = 0; index < 128; index++) deep.append_c (']');
  // Both JSON-GLib's parser and the retained-size walk recurse, so depth is a
  // stack bound rather than a heap one.
  assert (budget_rejects (deep.str));
}

private static void tree_values_are_charged_by_retained_size () {
  var tree = dense_array_node (20000);
  size_t retained = Convex.retained_node_bytes (tree);
  size_t serialized = Convex.node_text (tree).length;
  assert (retained >= (size_t) 20000 * Convex.JSON_NODE_RETAINED_BYTES);
  // Charging the serialized length understated this shape by more than forty
  // times, which is exactly how a bounded queue became an unbounded one.
  assert (retained > serialized * 40);

  var text = new Json.Node (NodeType.VALUE);
  text.set_string (large_string (200000));
  // A long string is one node, so its wire size is already the honest cost.
  assert (Convex.retained_node_bytes (text) < (size_t) 204096);
}

private static void tree_shaped_updates_stay_inside_the_delivery_budget () {
  var subscription = new Subscription (7, "demo:state", object_args ());
  // 60 000 elements retain about 7.7 MiB each. Four of them are over 30 MiB of
  // live JSON-GLib nodes but under 500 KB of serialized text.
  for (int index = 0; index < 4; index++) subscription.publish (dense_array_node (60000), null);
  assert (subscription.pending_count () == 1);
  assert (subscription.pending_byte_count () <= 8 * 1024 * 1024);
  assert (subscription.pending_byte_count () > 7 * 1024 * 1024);
  subscription.invalidate ();
  assert (subscription.pending_count () == 0);
  assert (subscription.pending_byte_count () == 0);
}

private static void an_oversized_tree_becomes_a_bounded_protocol_error () {
  var subscription = new Subscription (10, "demo:state", object_args ());
  string? observed_name = null;
  bool observed_value = false;
  subscription.updated.connect ((value, failure) => {
    if (failure != null) observed_name = failure.name;
    if (value != null) observed_value = true;
  });
  subscription.publish (dense_array_node (200000), null);
  drain_main_context ();
  // The relay reports the bound instead of holding the tree or dropping the
  // subscriber silently.
  assert (observed_name == "ProtocolError");
  assert (!observed_value);
  assert (subscription.pending_count () == 0);
  assert (subscription.pending_byte_count () == 0);
}

private static void rehydration_signature_separates_name_and_message () {
  var subscription = new Subscription (8, "demo:state", object_args ());
  var observed = new Gee.ArrayList<string> ();
  subscription.updated.connect ((value, failure) => {
    if (failure != null) observed.add (failure.name + "|" + failure.message);
  });
  subscription.publish (null, new FunctionError ("A", "B:C"));
  drain_main_context ();
  subscription.prepare_rehydration ();
  // Raw concatenation gave these two different failures one signature, so the
  // second was wrongly suppressed as an unchanged rehydration.
  subscription.publish (null, new FunctionError ("A:B", "C"));
  drain_main_context ();
  assert (observed.size == 2);
  assert (observed.get (0) == "A|B:C");
  assert (observed.get (1) == "A:B|C");
}

private static void a_republishing_callback_releases_its_reservation_once () {
  var subscription = new Subscription (9, "demo:state", object_args ());
  int deliveries = 0;
  subscription.updated.connect ((value, failure) => {
    deliveries++;
    if (deliveries == 1) subscription.publish (number_node (2), null);
  });
  subscription.publish (number_node (1), null);
  drain_main_context ();
  assert (deliveries == 2);
  assert (subscription.pending_count () == 0);
  assert (subscription.pending_byte_count () == 0);
}

private static void a_revoking_callback_releases_its_reservation_once () {
  var subscription = new Subscription (11, "demo:state", object_args ());
  int deliveries = 0;
  subscription.updated.connect ((value, failure) => {
    deliveries++;
    // Revoking from inside the callback releases the in-flight reservation as
    // part of the reset, so the return path must not subtract it again.
    subscription.invalidate ();
  });
  subscription.publish (number_node (1), null);
  subscription.publish (number_node (2), null);
  drain_main_context ();
  assert (deliveries == 1);
  assert (subscription.pending_count () == 0);
  assert (subscription.pending_byte_count () == 0);
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

private static void rehydration_compares_error_logs () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (6, "demo:state", args);
  var observed_logs = new Gee.ArrayList<string> ();
  subscription.updated.connect ((value, failure) => {
    if (failure != null) observed_logs.add (failure.logs[0]);
  });
  subscription.publish (null, new FunctionError ("FunctionError", "same failure", null, { "first log" }));
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  subscription.prepare_rehydration ();
  // The error fields are otherwise identical. A changed log is observable
  // server output and must not be mistaken for an unchanged rehydration.
  subscription.publish (null, new FunctionError ("FunctionError", "same failure", null, { "second log" }));
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  assert (observed_logs.size == 2);
  assert (observed_logs.get (0) == "first log");
  assert (observed_logs.get (1) == "second log");
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

private static string large_string (int bytes, char fill = 'x') {
  var builder = new StringBuilder ();
  for (int index = 0; index < bytes; index++) builder.append_c (fill);
  return builder.str;
}

private static Json.Node large_string_node (int bytes, char fill = 'x') {
  var node = new Json.Node (NodeType.VALUE);
  node.set_string (large_string (bytes, fill));
  return node;
}

private static void in_flight_reservation_refills_after_publish () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (4, "demo:state", args);
  int deliveries = 0;
  subscription.updated.connect ((value, failure) => { deliveries++; });
  for (int index = 0; index < 4; index++) subscription.publish (large_string_node (1900 * 1024), null);
  assert (subscription.pending_count () == 4);
  bool observed_in_flight = false;
  Subscription.before_delivery_for_test = (current) => {
    if (observed_in_flight) return;
    observed_in_flight = true;
    // poll() has happened, but count and bytes still include this callback.
    assert (current.pending_count () == 4);
    assert (current.pending_byte_count () > 7 * 1024 * 1024);
    current.publish (large_string_node (1900 * 1024, 'z'), null);
    assert (current.pending_count () <= 4);
    assert (current.pending_byte_count () <= 8 * 1024 * 1024);
  };
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  Subscription.before_delivery_for_test = null;
  assert (observed_in_flight);
  assert (subscription.pending_count () == 0);
  assert (subscription.pending_byte_count () == 0);
  int delivered_before_refill = deliveries;
  subscription.publish (number_node (99), null);
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  assert (deliveries == delivered_before_refill + 1);
}

private static void revocation_releases_log_and_runtime_reservation_once () {
  var args = new Json.Node (NodeType.OBJECT);
  args.set_object (new Json.Object ());
  var subscription = new Subscription (5, "demo:state", args);
  string[] logs = { large_string (512 * 1024), large_string (512 * 1024, 'y') };
  var failure = new FunctionError ("FunctionError", "large logged failure", null, logs);
  int deliveries = 0;
  subscription.updated.connect ((value, error) => { deliveries++; });
  subscription.publish (null, failure);
  bool revoked = false;
  Subscription.before_delivery_for_test = (current) => {
    revoked = true;
    assert (current.pending_count () == 1);
    // This is larger than the raw log bytes because encoded JSON and runtime
    // overhead remain charged through callback publication.
    assert (current.pending_byte_count () > 1024 * 1024);
    current.invalidate ();
  };
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
  Subscription.before_delivery_for_test = null;
  assert (revoked);
  assert (deliveries == 0);
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
  Test.add_func ("/convex/subscription/rehydration-error-logs", rehydration_compares_error_logs);
  Test.add_func ("/convex/protocol/uint32-bounds", uint32_numbers_are_strict);
  Test.add_func ("/convex/protocol/null-json-root", json_documents_without_a_value_are_protocol_errors);
  Test.add_func ("/convex/protocol/retained-json-budget", json_budget_bounds_the_tree_before_it_is_parsed);
  Test.add_func ("/convex/protocol/retained-node-size", tree_values_are_charged_by_retained_size);
  Test.add_func ("/convex/subscription/rehydration-name-message", rehydration_signature_separates_name_and_message);
  Test.add_func ("/convex/live/stopped-reader-budget", stopped_reader_budget_is_bounded);
  Test.add_func ("/convex/live/tree-shaped-budget", tree_shaped_updates_stay_inside_the_delivery_budget);
  Test.add_func ("/convex/live/oversized-tree-bounded-error", an_oversized_tree_becomes_a_bounded_protocol_error);
  Test.add_func ("/convex/live/republish-release-once", a_republishing_callback_releases_its_reservation_once);
  Test.add_func ("/convex/live/revoke-release-once", a_revoking_callback_releases_its_reservation_once);
  Test.add_func ("/convex/live/in-flight-refill", in_flight_reservation_refills_after_publish);
  Test.add_func ("/convex/live/revocation-log-runtime-budget", revocation_releases_log_and_runtime_reservation_once);
  Test.add_func ("/convex/live/invalidation-barrier", invalidation_is_a_delivery_barrier);
  return Test.run ();
}
