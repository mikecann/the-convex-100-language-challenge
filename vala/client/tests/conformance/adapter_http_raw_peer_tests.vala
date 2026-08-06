using GLib;
using Gee;
using Json;

private static Json.Object latest_adapter_http_event (ArrayList<string> events) throws Error {
  assert (events.size > 0);
  return Convex.parse_json (events.get (events.size - 1)).get_object ();
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
    for (int index = 0; index < modes.length; index++) {
      string id = "http-" + index.to_string ();
      adapter.handle ("{\"id\":" + Convex.json_string (id) + ",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}");
      var event = latest_adapter_http_event (events);
      assert (event.get_string_member ("id") == id);
      if (index < 5) {
        assert (event.get_string_member ("type") == "error");
        assert (event.get_object_member ("error").get_string_member ("name") == "TransportError");
      } else if (index < 11) {
        assert (event.get_string_member ("type") == "error");
        assert (event.get_object_member ("error").get_string_member ("name") == "ProtocolError");
      } else if (index == 11) {
        assert (event.get_string_member ("type") == "error");
        assert (event.get_object_member ("error").get_string_member ("name") == "FunctionError");
        // A later adapter-schema failure must not reuse this HTTP error.
        adapter.handle ("{\"id\":\"invalid-after-function\",\"op\":\"close\",\"extra\":true}");
        var invalid = latest_adapter_http_event (events);
        assert (invalid.get_string_member ("type") == "error");
        assert (invalid.get_object_member ("error").get_string_member ("name") == "ProtocolError");
      } else {
        assert (event.get_string_member ("type") == "result");
        assert (event.get_int_member ("value") == 7);
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
