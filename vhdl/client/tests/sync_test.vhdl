-- sync_test.vhdl - unit coverage for convex_sync.vhdl against a real TCP
-- peer: the Dockerfile starts a fixture /api/sync server (syncfix.c)
-- that performs the WS Upgrade handshake, replies to a subscription's
-- Add with a Transition carrying the query's value, and reports a
-- different value on each connection it accepts -- so forcing a
-- reconnect with debugDisconnect and observing the value actually
-- change end to end proves this client's reconnect-and-resubscribe path
-- for real, not just that it compiles.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_http.all;
use work.convex_native.all;
use work.convex_sync.all;

entity sync_test is
end entity sync_test;

architecture behav of sync_test is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable ep : http_endpoint_t;
    variable ok : boolean;
    variable m : sync_manager_t;
    variable r : integer;

    variable has_event : boolean;
    variable kind : sync_event_kind_t;
    variable sub_id : byte_array(0 to 63);
    variable sub_id_len : natural;
    variable value_json : byte_array(0 to 4095);
    variable value_len : natural;
    variable logs_json : byte_array(0 to 4095);
    variable logs_len : natural;
    variable error_name : byte_array(0 to 15);
    variable error_name_len : natural;
    variable error_message : byte_array(0 to 255);
    variable error_message_len : natural;
    variable error_data : byte_array(0 to 1023);
    variable error_data_len : natural;
    variable step_ok : boolean;

    variable args_buf : byte_array(0 to 15);
    variable args_len : natural;
    variable attempts : natural;
  begin
    http_parse_endpoint("ws://127.0.0.1:44304/", ep, ok);
    assert ok report "parsing the sync fixture endpoint failed" severity failure;

    sync_init(m, ep);

    args_len := 0;
    buf_put_str(args_buf, args_len, "{}");
    sync_subscribe(xport_req, m, "s1", "demo:state", args_buf, args_len, ok);
    assert ok report "sync_subscribe failed" severity failure;

    -- Waits for the first SYNC_UPDATED event, bounded so a real protocol
    -- bug hangs this test instead of the whole Docker build.
    attempts := 0;
    loop
      sync_step(xport_req, m, 100, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                error_data, error_data_len, step_ok);
      assert step_ok report "sync_step reported an internal failure" severity failure;
      exit when has_event;
      attempts := attempts + 1;
      assert attempts < 200 report "timed out waiting for the initial Live value" severity failure;
    end loop;
    assert kind = SYNC_UPDATED report "the initial event should be SYNC_UPDATED" severity failure;
    assert buf_eq_str(sub_id, 0, sub_id_len, "s1")
      report "the initial event's subscription id was wrong" severity failure;
    assert buf_eq_str(value_json, 0, value_len, "{""count"":0}")
      report "the initial Live value should be {""count"":0}" severity failure;

    sync_debug_disconnect(xport_req, m, ok);
    assert ok report "sync_debug_disconnect failed" severity failure;

    -- Forcing the disconnect above must make sync_step reconnect and
    -- resend this subscription's Add on its own; the fixture answers the
    -- second connection with a different value, so seeing that new
    -- value here is the actual proof reconnect-and-resubscribe worked.
    attempts := 0;
    loop
      sync_step(xport_req, m, 100, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                error_data, error_data_len, step_ok);
      assert step_ok report "sync_step reported an internal failure after reconnect" severity failure;
      exit when has_event;
      attempts := attempts + 1;
      assert attempts < 200 report "timed out waiting for the post-reconnect Live value" severity failure;
    end loop;
    assert kind = SYNC_UPDATED report "the reconnect event should be SYNC_UPDATED" severity failure;
    assert buf_eq_str(value_json, 0, value_len, "{""count"":1}")
      report "the post-reconnect Live value should be {""count"":1}, proving the resubscribe reached the new connection"
      severity failure;

    report "PASS sync_test";
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
