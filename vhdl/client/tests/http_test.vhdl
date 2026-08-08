-- http_test.vhdl - unit coverage for convex_http.vhdl: URL parsing and
-- request framing need no network at all, but response decoding (plain
-- Content-Length and chunked Transfer-Encoding) is only genuinely proven
-- against a real TCP peer, matching this project's other native clients'
-- hermetic-fixture-server style rather than mocking the transport away.
-- The Dockerfile starts two tiny one-shot fixture servers on fixed local
-- ports, each replaying one canned HTTP response exactly once.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_json.all;
use work.convex_native.all;
use work.convex_http.all;

entity http_test is
end entity http_test;

architecture behav of http_test is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable ep : http_endpoint_t;
    variable ok : boolean;
    variable buf : byte_array(0 to 511);
    variable len : natural;
    variable r : integer;
    variable handle : integer;
    variable status : integer;
    variable header_buf : byte_array(0 to 1023);
    variable header_len : natural;
    variable resp_body : byte_array(0 to 1023);
    variable body_len : natural;
    variable hv : byte_array(0 to 127);
    variable hv_len : natural;
    variable found : boolean;
    variable toks : json_tok_array(0 to 15);
    variable ntoks : natural;
    variable jok : boolean;
    variable t : integer;
    variable ival : integer;
  begin
    -- === URL parsing, no network ===
    http_parse_endpoint("https://example.convex.cloud:8443/base/", ep, ok);
    assert ok report "parsing a valid https URL failed" severity failure;
    assert ep.tls report "https URL should set tls" severity failure;
    assert buf_eq_str(ep.host, 0, ep.host_len, "example.convex.cloud")
      report "host did not parse correctly" severity failure;
    assert ep.port_num = 8443 report "explicit port did not parse correctly" severity failure;
    assert buf_eq_str(ep.base_path, 0, ep.base_path_len, "/base")
      report "base_path should have its trailing slash trimmed" severity failure;

    http_parse_endpoint("http://localhost", ep, ok);
    assert ok report "parsing a bare http URL failed" severity failure;
    assert not ep.tls report "http URL should not set tls" severity failure;
    assert ep.port_num = 80 report "http URL should default to port 80" severity failure;
    assert ep.base_path_len = 0 report "a bare URL should have an empty base_path" severity failure;

    http_parse_endpoint("https://example.convex.cloud", ep, ok);
    assert ok and ep.port_num = 443 report "https URL should default to port 443" severity failure;

    http_parse_endpoint("ftp://example.com", ep, ok);
    assert not ok report "an unsupported scheme must be rejected" severity failure;

    http_parse_endpoint("not a url", ep, ok);
    assert not ok report "a malformed URL must be rejected" severity failure;

    -- === request framing, no network ===
    len := 0;
    http_write_request_line(buf, len, "POST", ep, "/api/query");
    http_write_header(buf, len, "Accept", "application/json");
    http_write_header_int(buf, len, "Content-Length", 11);
    http_end_headers(buf, len);
    assert buf_eq_str(buf, 0, len,
      "POST /api/query HTTP/1.1" & character'val(13) & character'val(10) &
      "Accept: application/json" & character'val(13) & character'val(10) &
      "Content-Length: 11" & character'val(13) & character'val(10) &
      character'val(13) & character'val(10))
      report "request framing did not match" severity failure;

    -- === header lookup against a canned header block ===
    len := 0;
    buf_put_str(buf, len, "HTTP/1.1 200 OK" & character'val(13) & character'val(10));
    buf_put_str(buf, len, "Content-Type: application/json" & character'val(13) & character'val(10));
    buf_put_str(buf, len, "content-length: 42 " & character'val(13) & character'val(10));
    buf_put_str(buf, len, character'val(13) & character'val(10));
    hv_len := 0;
    http_header_value(buf, len, "Content-Type", hv, hv_len, found);
    assert found and buf_eq_str(hv, 0, hv_len, "application/json")
      report "case-sensitive-name header lookup failed" severity failure;
    hv_len := 0;
    http_header_value(buf, len, "CONTENT-LENGTH", hv, hv_len, found);
    assert found and buf_eq_str(hv, 0, hv_len, "42")
      report "case-insensitive header lookup with trimming failed" severity failure;
    hv_len := 0;
    http_header_value(buf, len, "X-Missing", hv, hv_len, found);
    assert not found report "a missing header must not be found" severity failure;

    -- === a real Content-Length response from a local fixture server ===
    http_parse_endpoint("http://127.0.0.1:44301/", ep, ok);
    assert ok report "parsing the fixture endpoint failed" severity failure;
    http_connect(xport_req, ep, handle, ok);
    assert ok report "connecting to the Content-Length fixture failed" severity failure;
    len := 0;
    http_write_request_line(buf, len, "GET", ep, "/api/query");
    http_write_header(buf, len, "Host", "127.0.0.1");
    http_end_headers(buf, len);
    http_send(xport_req, handle, buf, len, ok);
    assert ok report "sending the request to the Content-Length fixture failed" severity failure;
    http_read_response(xport_req, handle, 5000, status, header_buf, header_len, resp_body, body_len, ok);
    assert ok report "reading the Content-Length response failed" severity failure;
    assert status = 200 report "Content-Length fixture should answer 200" severity failure;
    json_parse(resp_body, body_len, toks, ntoks, jok);
    assert jok report "the Content-Length fixture's body should be valid JSON" severity failure;
    json_object_get(resp_body, toks, ntoks, toks'low, "status", t, found);
    assert found and json_tok_eq_str(resp_body, toks, t, "success")
      report "the Content-Length fixture's body did not decode as expected" severity failure;
    json_object_get(resp_body, toks, ntoks, toks'low, "value", t, found);
    assert found report "the Content-Length fixture's value field was missing" severity failure;
    json_object_get(resp_body, toks, ntoks, t, "count", t, found);
    assert found report "the Content-Length fixture's count field was missing" severity failure;
    json_tok_as_int(resp_body, toks, t, ival, jok);
    assert jok and ival = 7 report "the Content-Length fixture's count should be 7" severity failure;
    xport_call(xport_req, CMD_CLOSE, handle, 0, r);

    -- === a real chunked response from a local fixture server ===
    http_parse_endpoint("http://127.0.0.1:44302/", ep, ok);
    http_connect(xport_req, ep, handle, ok);
    assert ok report "connecting to the chunked fixture failed" severity failure;
    len := 0;
    http_write_request_line(buf, len, "GET", ep, "/api/query");
    http_write_header(buf, len, "Host", "127.0.0.1");
    http_end_headers(buf, len);
    http_send(xport_req, handle, buf, len, ok);
    assert ok report "sending the request to the chunked fixture failed" severity failure;
    http_read_response(xport_req, handle, 5000, status, header_buf, header_len, resp_body, body_len, ok);
    assert ok report "reading the chunked response failed" severity failure;
    assert status = 200 report "chunked fixture should answer 200" severity failure;
    assert buf_eq_str(resp_body, 0, body_len, "hello world")
      report "chunked body did not reassemble to ""hello world""" severity failure;
    xport_call(xport_req, CMD_CLOSE, handle, 0, r);

    report "PASS http_test";
    -- convex_transport's clock_gen process free-runs forever, so without
    -- this the simulation would never reach quiescence on its own; every
    -- program in this client that instantiates convex_transport must
    -- call CMD_EXIT explicitly to terminate, exactly as
    -- transport_smoke.vhdl already does.
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
