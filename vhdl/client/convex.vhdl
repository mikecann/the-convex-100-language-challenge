-- convex.vhdl - the public native VHDL client facade. Calls one Convex
-- query, mutation, or action over the documented JSON HTTP API and
-- decodes the response envelope Convex's own API always returns:
-- {"status":"success","value":<value>,"logLines":[...]} or
-- {"status":"error","errorMessage":<string>,"errorData":<value>,
-- "logLines":[...]}. Built directly on convex_http.vhdl and
-- convex_json.vhdl; convex_sync.vhdl is the separate Live half of this
-- client, reached directly rather than through this file, matching how
-- the adapter and examples/basics both use them side by side.
use work.convex_buffer.all;
use work.convex_json.all;
use work.convex_http.all;
use work.convex_native.all;

package convex is

  constant CLIENT_STATUS_CAP : natural := 4096;

  -- Calls one Convex function. op must be "query", "mutation" or
  -- "action". args_json must be a complete JSON object's text (this
  -- client never builds one from a generic value tree; every caller
  -- writes the exact shape it needs directly, matching
  -- convex_buffer.vhdl and convex_json.vhdl's own style). auth_token_len
  -- of 0 means no Authorization header is sent.
  --
  -- On a transport-level failure (connect, TLS, malformed HTTP
  -- response), ok is false and http_status carries no meaning. On a
  -- genuine Convex response, ok is true and is_function_error
  -- distinguishes a successful result (value_json/logs_json valid) from
  -- a function error (error_name/error_message/error_data_json valid,
  -- error_data_len = 0 meaning "no data").
  procedure client_call(
    signal rq            : inout xport_req_t;
    ep                   : in http_endpoint_t;
    auth_token           : in byte_array;
    auth_token_len       : in natural;
    op                   : in string;
    path                 : in string;
    args_json            : in byte_array;
    args_len             : in natural;
    is_function_error    : out boolean;
    value_json           : inout byte_array;
    value_len            : out natural;
    logs_json            : inout byte_array;
    logs_len             : out natural;
    error_message        : inout byte_array;
    error_message_len    : out natural;
    error_data_json      : inout byte_array;
    error_data_len       : out natural;
    ok                   : out boolean
  );

end package convex;

package body convex is

  procedure client_call(
    signal rq            : inout xport_req_t;
    ep                   : in http_endpoint_t;
    auth_token           : in byte_array;
    auth_token_len       : in natural;
    op                   : in string;
    path                 : in string;
    args_json            : in byte_array;
    args_len             : in natural;
    is_function_error    : out boolean;
    value_json           : inout byte_array;
    value_len            : out natural;
    logs_json            : inout byte_array;
    logs_len             : out natural;
    error_message        : inout byte_array;
    error_message_len    : out natural;
    error_data_json      : inout byte_array;
    error_data_len       : out natural;
    ok                   : out boolean
  ) is
    variable handle : integer;
    variable connect_ok : boolean;
    variable payload_buf : byte_array(0 to CLIENT_STATUS_CAP - 1);
    variable payload_len : natural := 0;
    variable req_buf : byte_array(0 to CLIENT_STATUS_CAP - 1);
    variable req_len : natural := 0;
    variable send_ok : boolean;
    variable status : integer;
    variable header_buf : byte_array(0 to 4095);
    variable header_len : natural;
    variable body_buf : byte_array(0 to CLIENT_STATUS_CAP - 1);
    variable body_len : natural;
    variable read_ok : boolean;
    variable toks : json_tok_array(0 to 127);
    variable ntoks : natural;
    variable parse_ok : boolean;
    variable status_tok, t, logs_tok : integer;
    variable found : boolean;
    variable r : integer;
  begin
    ok := false;
    is_function_error := false;
    value_len := 0;
    logs_len := 0;
    error_message_len := 0;
    error_data_len := 0;

    http_connect(rq, ep, handle, connect_ok);
    if not connect_ok then
      return;
    end if;

    -- {"path":<path>,"args":<args_json>,"format":"json"}
    buf_put_byte(payload_buf, payload_len, character'pos('{'));
    json_put_string(payload_buf, payload_len, "path");
    buf_put_byte(payload_buf, payload_len, character'pos(':'));
    json_put_string(payload_buf, payload_len, path);
    buf_put_byte(payload_buf, payload_len, character'pos(','));
    json_put_string(payload_buf, payload_len, "args");
    buf_put_byte(payload_buf, payload_len, character'pos(':'));
    buf_put_slice(payload_buf, payload_len, args_json, 0, args_len);
    buf_put_byte(payload_buf, payload_len, character'pos(','));
    json_put_string(payload_buf, payload_len, "format");
    buf_put_byte(payload_buf, payload_len, character'pos(':'));
    json_put_string(payload_buf, payload_len, "json");
    buf_put_byte(payload_buf, payload_len, character'pos('}'));

    http_write_request_line(req_buf, req_len, "POST", ep, "/api/" & op);
    -- ep's host is a byte slice, not a VHDL string, so this one header is
    -- composed by hand rather than through http_write_header, exactly
    -- like convex_ws.vhdl's ws_handshake does for the same reason.
    buf_put_str(req_buf, req_len, "Host: ");
    buf_put_slice(req_buf, req_len, ep.host, 0, ep.host_len);
    buf_put_byte(req_buf, req_len, 13);
    buf_put_byte(req_buf, req_len, 10);
    http_write_header(req_buf, req_len, "Accept", "application/json");
    http_write_header(req_buf, req_len, "Content-Type", "application/json");
    if auth_token_len > 0 then
      buf_put_str(req_buf, req_len, "Authorization: Bearer ");
      buf_put_slice(req_buf, req_len, auth_token, 0, auth_token_len);
      buf_put_byte(req_buf, req_len, 13);
      buf_put_byte(req_buf, req_len, 10);
    end if;
    http_write_header_int(req_buf, req_len, "Content-Length", payload_len);
    http_end_headers(req_buf, req_len);
    buf_put_slice(req_buf, req_len, payload_buf, 0, payload_len);

    http_send(rq, handle, req_buf, req_len, send_ok);
    if not send_ok then
      return;
    end if;
    http_read_response(rq, handle, 10000, status, header_buf, header_len, body_buf, body_len, read_ok);
    xport_call(rq, CMD_CLOSE, handle, 0, r);
    if not read_ok or status /= 200 then
      return;
    end if;

    json_parse(body_buf, body_len, toks, ntoks, parse_ok);
    if not parse_ok or toks(toks'low).kind /= JSON_OBJECT then
      return;
    end if;
    json_object_get(body_buf, toks, ntoks, toks'low, "status", status_tok, found);
    if not found or toks(status_tok).kind /= JSON_STRING then
      return;
    end if;

    json_object_get(body_buf, toks, ntoks, toks'low, "logLines", logs_tok, found);
    if found then
      buf_put_slice(logs_json, logs_len, body_buf, toks(logs_tok).start, toks(logs_tok).stop - toks(logs_tok).start);
    else
      buf_put_str(logs_json, logs_len, "[]");
    end if;

    if json_tok_eq_str(body_buf, toks, status_tok, "error") then
      is_function_error := true;
      json_object_get(body_buf, toks, ntoks, toks'low, "errorMessage", t, found);
      if found and toks(t).kind = JSON_STRING then
        json_tok_get_str(body_buf, toks, t, error_message, error_message_len);
      else
        buf_put_str(error_message, error_message_len, "function error");
      end if;
      json_object_get(body_buf, toks, ntoks, toks'low, "errorData", t, found);
      if found then
        buf_put_slice(error_data_json, error_data_len, body_buf, toks(t).start, toks(t).stop - toks(t).start);
      end if;
      ok := true;
      return;
    elsif not json_tok_eq_str(body_buf, toks, status_tok, "success") then
      return;
    end if;

    json_object_get(body_buf, toks, ntoks, toks'low, "value", t, found);
    if not found then
      return;
    end if;
    buf_put_slice(value_json, value_len, body_buf, toks(t).start, toks(t).stop - toks(t).start);
    ok := true;
  end procedure client_call;

end package body convex;
