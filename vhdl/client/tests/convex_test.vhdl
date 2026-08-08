-- convex_test.vhdl - unit coverage for convex.vhdl's client_call: the
-- request envelope it builds and the two response envelope shapes
-- Convex's HTTP API returns (success and function error), against real
-- fixture servers reusing httpfix.c's role.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_http.all;
use work.convex_native.all;
use work.convex.all;

entity convex_test is
end entity convex_test;

architecture behav of convex_test is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable ep : http_endpoint_t;
    variable ok : boolean;
    variable args : byte_array(0 to 15);
    variable args_len : natural;
    variable is_function_error : boolean;
    variable value_json : byte_array(0 to 1023);
    variable value_len : natural;
    variable logs_json : byte_array(0 to 1023);
    variable logs_len : natural;
    variable error_message : byte_array(0 to 255);
    variable error_message_len : natural;
    variable error_data_json : byte_array(0 to 1023);
    variable error_data_len : natural;
    variable no_token : byte_array(0 to 0);
    variable r : integer;
  begin
    args_len := 0;
    buf_put_str(args, args_len, "{}");

    -- === success envelope ===
    http_parse_endpoint("http://127.0.0.1:44305/", ep, ok);
    assert ok report "parsing the success fixture endpoint failed" severity failure;
    client_call(xport_req, ep, no_token, 0, "query", "demo:state", args, args_len,
                is_function_error, value_json, value_len, logs_json, logs_len,
                error_message, error_message_len, error_data_json, error_data_len, ok);
    assert ok report "client_call against the success fixture failed" severity failure;
    assert not is_function_error report "the success fixture should not report a function error" severity failure;
    assert buf_eq_str(value_json, 0, value_len, "{""count"":3}")
      report "the success fixture's value did not decode as expected" severity failure;
    assert buf_eq_str(logs_json, 0, logs_len, "[""log one""]")
      report "the success fixture's logLines did not decode as expected" severity failure;

    -- === function error envelope ===
    http_parse_endpoint("http://127.0.0.1:44306/", ep, ok);
    assert ok report "parsing the error fixture endpoint failed" severity failure;
    client_call(xport_req, ep, no_token, 0, "mutation", "demo:increment", args, args_len,
                is_function_error, value_json, value_len, logs_json, logs_len,
                error_message, error_message_len, error_data_json, error_data_len, ok);
    assert ok report "client_call against the error fixture failed" severity failure;
    assert is_function_error report "the error fixture should report a function error" severity failure;
    assert buf_eq_str(error_message, 0, error_message_len, "room is full")
      report "the error fixture's errorMessage did not decode as expected" severity failure;
    assert buf_eq_str(error_data_json, 0, error_data_len, "{""code"":429}")
      report "the error fixture's errorData did not decode as expected" severity failure;

    report "PASS convex_test";
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
