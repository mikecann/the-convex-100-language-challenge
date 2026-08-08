-- ws_test.vhdl - unit coverage for convex_ws.vhdl against a real TCP
-- peer: the Dockerfile starts a one-shot fixture WebSocket server
-- (wsfix.c) that performs the Upgrade handshake, sends one complete
-- frame, a fragmented message, a Ping (verifying this client answers
-- with an exact Pong), and a Close -- proving the handshake, masked
-- encode, unmasked decode, fragmentation reassembly, and transparent
-- Ping/Pong handling all work end to end rather than only compiling.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_http.all;
use work.convex_native.all;
use work.convex_ws.all;

entity ws_test is
end entity ws_test;

architecture behav of ws_test is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable ep : http_endpoint_t;
    variable ok : boolean;
    variable handle : integer;
    variable payload : byte_array(0 to 4095);
    variable payload_len : natural;
    variable opcode : ws_opcode_t;
    variable r : integer;
  begin
    http_parse_endpoint("ws://127.0.0.1:44303/api/sync", ep, ok);
    assert ok report "parsing the ws fixture endpoint failed" severity failure;
    assert not ep.tls report "a ws:// URL must not set tls" severity failure;

    http_connect(xport_req, ep, handle, ok);
    assert ok report "connecting to the WebSocket fixture failed" severity failure;

    ws_handshake(xport_req, handle, ep, "/api/sync", 5000, ok);
    assert ok report "the WebSocket Upgrade handshake failed" severity failure;

    ws_read_message(xport_req, handle, 5000, opcode, payload, payload_len, ok);
    assert ok report "reading the first fixture message failed" severity failure;
    assert opcode = WS_TEXT report "the first fixture message should be TEXT" severity failure;
    assert buf_eq_str(payload, 0, payload_len, "hello")
      report "the first fixture message should be ""hello""" severity failure;

    ws_read_message(xport_req, handle, 5000, opcode, payload, payload_len, ok);
    assert ok report "reading the fragmented fixture message failed" severity failure;
    assert opcode = WS_TEXT report "the reassembled fixture message should be TEXT" severity failure;
    assert buf_eq_str(payload, 0, payload_len, "foobar")
      report "fragmented frames ""foo""+""bar"" should reassemble to ""foobar""" severity failure;

    -- The fixture's Ping is answered transparently inside this call, and
    -- the fixture itself verifies the Pong payload matched before it
    -- sends the Close this call actually returns.
    ws_read_message(xport_req, handle, 5000, opcode, payload, payload_len, ok);
    assert ok report "reading past the Ping to the Close failed" severity failure;
    assert opcode = WS_CLOSE report "the final fixture message should be CLOSE" severity failure;

    xport_call(xport_req, CMD_CLOSE, handle, 0, r);
    report "PASS ws_test";
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
