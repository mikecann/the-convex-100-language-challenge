using GLib;
using Gee;
using Json;

private static Json.Object latest_adapter_http_event (ArrayList<string> events) throws Error {
  assert (events.size > 0);
  return Convex.parse_json (events.get (events.size - 1)).get_object ();
}

// The expected adapter classification for each fixture response. "result" is
// the recovery call which must succeed on a fresh connection afterwards.
private static string[] adapter_http_expectations () {
  string[] expected = {
    "TransportError", "TransportError", "TransportError", "TransportError", "TransportError",
    "ProtocolError", "ProtocolError", "ProtocolError", "ProtocolError", "ProtocolError", "ProtocolError",
    "FunctionError", "result",
    // A valid Convex error envelope on a non-2xx status keeps its structure.
    "FunctionError", "result",
    // Non-envelope and merely envelope-shaped non-2xx bodies stay transport.
    "TransportError", "result",
    "TransportError", "result",
    // Bodies short of their declared framing are transport failures too.
    "TransportError", "result",
    "TransportError", "result",
    // An empty 200 body has no JSON value at all.
    "ProtocolError", "result"
  };
  return expected;
}

private static void adapter_http_failures_are_structured_and_recover () {
  RawHttpMode[] modes = {
    RawHttpMode.STATUS_503_SUCCESS,
    RawHttpMode.FIXED_OVERSIZED,
    RawHttpMode.CHUNKED_OVERSIZED,
    RawHttpMode.SLOW_STREAM,
    RawHttpMode.DRIP_STREAM,
    RawHttpMode.MALFORMED_JSON,
    RawHttpMode.ROOT_ARRAY,
    RawHttpMode.MISSING_STATUS,
    RawHttpMode.STATUS_NUMBER,
    RawHttpMode.LOGS_NOT_ARRAY,
    RawHttpMode.ERROR_MISSING_MESSAGE,
    RawHttpMode.FUNCTION_ERROR,
    RawHttpMode.SUCCESS,
    RawHttpMode.FUNCTION_ERROR_560,
    RawHttpMode.SUCCESS,
    RawHttpMode.NON_ENVELOPE_400,
    RawHttpMode.SUCCESS,
    RawHttpMode.ERROR_BAD_LOGS_400,
    RawHttpMode.SUCCESS,
    RawHttpMode.TRUNCATED_CONTENT_LENGTH,
    RawHttpMode.SUCCESS,
    RawHttpMode.TRUNCATED_CHUNKED,
    RawHttpMode.SUCCESS,
    RawHttpMode.EMPTY_BODY,
    RawHttpMode.SUCCESS
  };
  try {
    Convex.Client.http_timeout_seconds_for_test = 1;
    var peer = new RawHttpPeer (modes);
    peer.start ();
    Environment.set_variable ("CONVEX_URL", "http://127.0.0.1:" + peer.port.to_string (), true);
    var adapter = new Adapter (new MainLoop ());
    var events = new ArrayList<string> ();
    adapter.emitted_for_test.connect ((event) => {
      assert (adapter.output_in_flight_count_for_test () == 1);
      assert (adapter.output_in_flight_bytes_for_test () >= event.length + 1 + 256);
      events.add (event);
    });
    string[] expectations = adapter_http_expectations ();
    assert (expectations.length == modes.length);
    for (int index = 0; index < modes.length; index++) {
      string id = "http-" + index.to_string ();
      adapter.handle ("{\"id\":" + Convex.json_string (id) + ",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}");
      var event = latest_adapter_http_event (events);
      assert (event.get_string_member ("id") == id);
      if (expectations[index] == "result") {
        assert (event.get_string_member ("type") == "result");
        assert (event.get_int_member ("value") == 7);
      } else {
        assert (event.get_string_member ("type") == "error");
        assert (event.get_object_member ("error").get_string_member ("name") == expectations[index]);
      }
      if (index == 11) {
        // A later adapter-schema failure must not reuse this HTTP error.
        adapter.handle ("{\"id\":\"invalid-after-function\",\"op\":\"close\",\"extra\":true}");
        var invalid = latest_adapter_http_event (events);
        assert (invalid.get_string_member ("type") == "error");
        assert (invalid.get_object_member ("error").get_string_member ("name") == "ProtocolError");
      }
      if (index == 13) {
        // The non-2xx function error must reach the controller with the same
        // structured data and logs a 2xx envelope would have carried.
        var failure = event.get_object_member ("error");
        assert (failure.get_string_member ("message") == "Uncaught ConvexError: boom");
        assert (failure.get_object_member ("data").get_string_member ("code") == "BOOM");
        var logs = event.get_array_member ("logs");
        assert (logs.get_length () == 1);
        assert (logs.get_string_element (0) == "peer log");
      }
      if (index == 3) assert (peer.wait_for_delayed_responses (1, 3 * 1000 * 1000));
      if (index == 4) assert (peer.wait_for_delayed_responses (2, 3 * 1000 * 1000));
    }
    adapter.handle ("{\"id\":\"close\",\"op\":\"close\"}");
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("adapter raw HTTP test failed: %s\n", error.message);
    assert_not_reached ();
  } finally {
    Convex.Client.http_timeout_seconds_for_test = 15;
  }
}

int main (string[] args) {
  Test.init (ref args);
  Test.add_func ("/convex/adapter/http/raw-peer/status-bounds-deadline-recovery", adapter_http_failures_are_structured_and_recover);
  return Test.run ();
}
