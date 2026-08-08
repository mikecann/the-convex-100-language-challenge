-- adapter.vhdl - the NDJSON adapter protocol v1 executable. This is test
-- infrastructure for the shared conformance harness, not part of the
-- educational client API: it decodes one command per input line, calls
-- the real client packages beside it (convex.vhdl for query/mutation/
-- action, convex_sync.vhdl for Live), and encodes one event per output
-- line. Everything Convex-specific already lives in those packages; this
-- file only speaks the adapter's own wire protocol and owns the single
-- driver process every xport_call in this whole client ultimately runs
-- on, matching every other program in this client.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_json.all;
use work.convex_http.all;
use work.convex_native.all;
use work.convex_ws.all;
use work.convex_sync.all;
use work.convex.all;

entity adapter is
end entity adapter;

architecture behav of adapter is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    constant adapter_language : string := "vhdl";
    constant adapter_implementation : string := "native-vhdl-ghdl-openssl-vhpidirect";

    -- === I/O mode: stdin/stdout, or one accepted ADAPTER_LISTEN connection ===
    variable use_tcp : boolean := false;
    variable ctrl_handle : integer := -1;

    -- === client/session state, created lazily on first command that needs it ===
    variable have_client : boolean := false;
    variable ep : http_endpoint_t;
    variable sm : sync_manager_t;
    variable auth_token : byte_array(0 to 511);
    variable auth_token_len : natural := 0;

    -- === scratch shared by every nested procedure below ===
    variable line_buf : byte_array(0 to 8191);
    variable line_len : natural;
    variable out_buf : byte_array(0 to 8191);
    variable out_len : natural;
    variable r, b, mask : integer;
    variable closed : boolean := false;

    variable toks : json_tok_array(0 to 255);
    variable ntoks : natural;
    variable parse_ok : boolean;
    variable id_buf : byte_array(0 to 127);
    variable id_len : natural;
    variable op_buf : byte_array(0 to 31);
    variable op_len : natural;

    -- runtime-version string, filled once at start-up from native.c's own
    -- recorded toolchain version (see the Dockerfile's runtime-version
    -- file), so the adapter never has to hand-maintain a second copy of
    -- the pinned GHDL version string.
    variable runtime_buf : byte_array(0 to 63);
    variable runtime_len : natural := 0;

    -- ------------------------------------------------------------------
    -- I/O primitives: every other procedure below reads/writes through
    -- exactly these two, so the stdin/stdout-vs-socket choice is made
    -- once, here, rather than scattered through every command handler.
    -- ------------------------------------------------------------------
    procedure read_input_line(ok : out boolean) is
      variable bb : integer;
    begin
      line_len := 0;
      ok := false;
      loop
        if use_tcp then
          xport_call(xport_req, CMD_READ_BYTE, ctrl_handle, 60000, bb);
        else
          xport_call(xport_req, CMD_STDIN_READ_BYTE, 60000, 0, bb);
        end if;
        if bb < 0 then
          return; -- EOF, timeout, or transport error: treat as the stream ending
        end if;
        if bb = 10 then -- '\n' ends the line
          ok := true;
          return;
        end if;
        if bb /= 13 then -- a bare '\r' before '\n' is dropped, not stored
          if line_len < line_buf'length then
            buf_put_byte(line_buf, line_len, bb);
          end if;
        end if;
      end loop;
    end procedure read_input_line;

    -- True if the command source has a byte ready right now (a
    -- zero-timeout peek), used to decide each loop iteration whether to
    -- read a command or spend the iteration polling the Live socket
    -- instead. A procedure, not a function: it calls xport_call, which
    -- (like every crossing of the request/acknowledge bus) contains a
    -- wait statement, and VHDL functions may never do so even indirectly.
    procedure check_input_ready(ready : out boolean) is
      variable m : integer;
    begin
      if use_tcp then
        xport_call(xport_req, CMD_WAIT_READY, ctrl_handle, 0, m);
        ready := m = 1;
        return;
      end if;
      xport_call(xport_req, CMD_WAIT_READY_STDIN, -1, 0, m);
      ready := m /= 0;
    end procedure check_input_ready;

    procedure emit_line is
      variable ww : integer;
    begin
      buf_put_byte(out_buf, out_len, 10);
      if use_tcp then
        for i in 0 to out_len - 1 loop
          xport_call(xport_req, CMD_WRITE_BYTE, ctrl_handle, out_buf(i), ww);
        end loop;
        xport_call(xport_req, CMD_WRITE_FLUSH, ctrl_handle, 0, ww);
      else
        for i in 0 to out_len - 1 loop
          xport_call(xport_req, CMD_STDOUT_WRITE_BYTE, out_buf(i), 0, ww);
        end loop;
        xport_call(xport_req, CMD_STDOUT_FLUSH, 0, 0, ww);
      end if;
    end procedure emit_line;

    procedure getenv(name : in string; value : inout byte_array; value_len : out natural; found : out boolean) is
      variable rr, lookup_len : integer;
    begin
      value_len := 0;
      xport_call(xport_req, CMD_GETENV_RESET, 0, 0, rr);
      for i in name'range loop
        xport_call(xport_req, CMD_GETENV_PUSH, character'pos(name(i)), 0, rr);
      end loop;
      xport_call(xport_req, CMD_GETENV_LOOKUP, 0, 0, lookup_len);
      found := lookup_len >= 0;
      if not found then
        return;
      end if;
      for i in 0 to lookup_len - 1 loop
        xport_call(xport_req, CMD_GETENV_BYTE, i, 0, rr);
        buf_put_byte(value, value_len, rr);
      end loop;
    end procedure getenv;

    -- ------------------------------------------------------------------
    -- event encoding
    -- ------------------------------------------------------------------
    procedure emit_ready is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "protocolVersion");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_int(out_buf, out_len, 1);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "id");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, id_buf, 0, id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "ready");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "language");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, adapter_language);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "implementation");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, adapter_implementation);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "runtime");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, runtime_buf, 0, runtime_len);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_ready;

    procedure emit_simple(kind : in string) is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "id");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, id_buf, 0, id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, kind);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_simple;

    procedure emit_error(name : in string; message : in string) is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "id");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, id_buf, 0, id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "error");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "error");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "name");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, name);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "message");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, message);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_error;

    procedure emit_result(
      value_json : in byte_array; value_len : in natural;
      logs_json : in byte_array; logs_len : in natural
    ) is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "id");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, id_buf, 0, id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "result");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "value");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_slice(out_buf, out_len, value_json, 0, value_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "logs");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_slice(out_buf, out_len, logs_json, 0, logs_len);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_result;

    procedure emit_call_function_error(
      message : in byte_array; message_len : in natural;
      data_json : in byte_array; data_len : in natural;
      logs_json : in byte_array; logs_len : in natural
    ) is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "id");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, id_buf, 0, id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "error");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "error");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "name");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "FunctionError");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "message");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, message, 0, message_len);
      if data_len > 0 then
        buf_put_byte(out_buf, out_len, character'pos(','));
        json_put_string(out_buf, out_len, "data");
        buf_put_byte(out_buf, out_len, character'pos(':'));
        buf_put_slice(out_buf, out_len, data_json, 0, data_len);
      end if;
      buf_put_byte(out_buf, out_len, character'pos('}'));
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "logs");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_slice(out_buf, out_len, logs_json, 0, logs_len);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_call_function_error;

    procedure emit_subscription_value(
      sub_id : in byte_array; sub_id_len : in natural;
      value_json : in byte_array; value_len : in natural;
      logs_json : in byte_array; logs_len : in natural
    ) is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "subscription");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "subscriptionId");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, sub_id, 0, sub_id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "value");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_slice(out_buf, out_len, value_json, 0, value_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "logs");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_slice(out_buf, out_len, logs_json, 0, logs_len);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_subscription_value;

    procedure emit_subscription_error(
      sub_id : in byte_array; sub_id_len : in natural;
      err_name : in byte_array; err_name_len : in natural;
      err_message : in byte_array; err_message_len : in natural
    ) is
    begin
      out_len := 0;
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "type");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string(out_buf, out_len, "subscription");
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "subscriptionId");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, sub_id, 0, sub_id_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "error");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      buf_put_byte(out_buf, out_len, character'pos('{'));
      json_put_string(out_buf, out_len, "name");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, err_name, 0, err_name_len);
      buf_put_byte(out_buf, out_len, character'pos(','));
      json_put_string(out_buf, out_len, "message");
      buf_put_byte(out_buf, out_len, character'pos(':'));
      json_put_string_bytes(out_buf, out_len, err_message, 0, err_message_len);
      buf_put_byte(out_buf, out_len, character'pos('}'));
      buf_put_byte(out_buf, out_len, character'pos('}'));
      emit_line;
    end procedure emit_subscription_error;

    -- ------------------------------------------------------------------
    -- command handling
    -- ------------------------------------------------------------------
    -- A byte_array-to-string cast for the handful of places (URL parsing,
    -- Convex function paths, subscription ids) that need a real VHDL
    -- `string` to call into convex_http.vhdl/convex_sync.vhdl with.
    function string_of(buf : byte_array; len : natural) return string is
      variable s : string(1 to len);
    begin
      for i in 1 to len loop
        s(i) := character'val(buf(buf'low + i - 1));
      end loop;
      return s;
    end function string_of;

    procedure ensure_client(ok : out boolean) is
      variable url_buf : byte_array(0 to 255);
      variable url_len : natural;
      variable found : boolean;
      variable ep_ok : boolean;
      variable token_buf : byte_array(0 to 511);
      variable token_len : natural;
      variable have_token : boolean;
    begin
      if have_client then
        ok := true;
        return;
      end if;
      getenv("CONVEX_URL", url_buf, url_len, found);
      if not found or url_len = 0 then
        emit_error("ProtocolError", "CONVEX_URL is required");
        ok := false;
        return;
      end if;
      http_parse_endpoint(string_of(url_buf, url_len), ep, ep_ok);
      if not ep_ok then
        emit_error("ProtocolError", "CONVEX_URL is not a valid deployment URL");
        ok := false;
        return;
      end if;
      sync_init(sm, ep);
      have_client := true;
      getenv("CONVEX_AUTH_TOKEN", token_buf, token_len, have_token);
      if have_token then
        auth_token_len := 0;
        buf_put_slice(auth_token, auth_token_len, token_buf, 0, token_len);
      end if;
      ok := true;
    end procedure ensure_client;

    procedure handle_call(op_text : in string; call_ok : out boolean) is
      variable client_ok : boolean;
      variable path_tok, args_tok : integer;
      variable found : boolean;
      variable path_buf : byte_array(0 to 255);
      variable path_len : natural;
      variable is_function_error : boolean;
      variable value_json : byte_array(0 to 4095);
      variable value_len : natural;
      variable logs_json : byte_array(0 to 4095);
      variable logs_len : natural;
      variable error_message : byte_array(0 to 511);
      variable error_message_len : natural;
      variable error_data : byte_array(0 to 2047);
      variable error_data_len : natural;
      variable empty_args : byte_array(0 to 1);
      variable empty_args_len : natural;
    begin
      call_ok := true;
      ensure_client(client_ok);
      if not client_ok then
        return;
      end if;
      json_object_get(line_buf, toks, ntoks, toks'low, "path", path_tok, found);
      path_len := 0;
      if found and toks(path_tok).kind = JSON_STRING then
        json_tok_get_str(line_buf, toks, path_tok, path_buf, path_len);
      end if;
      json_object_get(line_buf, toks, ntoks, toks'low, "args", args_tok, found);
      if not found then
        empty_args_len := 0;
        buf_put_str(empty_args, empty_args_len, "{}");
        client_call(xport_req, ep, auth_token, auth_token_len, op_text, string_of(path_buf, path_len),
                    empty_args, empty_args_len, is_function_error, value_json, value_len,
                    logs_json, logs_len, error_message, error_message_len, error_data, error_data_len, client_ok);
      else
        -- Passed as a slice, not the whole buffer plus a length: a
        -- slice's own 'low becomes the args span's real start offset
        -- inside client_call, rather than always reading from line_buf's
        -- own offset 0 regardless of where "args" actually sits in it.
        client_call(xport_req, ep, auth_token, auth_token_len, op_text, string_of(path_buf, path_len),
                    line_buf(toks(args_tok).start to toks(args_tok).stop - 1),
                    toks(args_tok).stop - toks(args_tok).start, is_function_error,
                    value_json, value_len, logs_json, logs_len, error_message, error_message_len,
                    error_data, error_data_len, client_ok);
      end if;
      if not client_ok then
        emit_error("TransportError", "the call failed");
        return;
      end if;
      if is_function_error then
        emit_call_function_error(error_message, error_message_len, error_data, error_data_len, logs_json, logs_len);
      else
        emit_result(value_json, value_len, logs_json, logs_len);
      end if;
    end procedure handle_call;

    procedure handle_line(command_line_closed : out boolean) is
      variable id_tok, op_tok, sub_id_tok, path_tok, args_tok, token_tok, version_tok : integer;
      variable found : boolean;
      variable version_ok : boolean;
      variable version_val : integer;
      variable call_ok : boolean;
      variable sub_id_buf : byte_array(0 to 63);
      variable sub_id_len : natural;
      variable path_buf : byte_array(0 to 127);
      variable path_len : natural;
      variable args_buf : byte_array(0 to 2047);
      variable args_len : natural;
      variable token_buf : byte_array(0 to 511);
      variable token_len : natural;
      variable client_ok : boolean;
      variable sub_ok : boolean;
      variable empty_args : byte_array(0 to 1);
      variable empty_args_len : natural;
    begin
      command_line_closed := false;
      json_parse(line_buf, line_len, toks, ntoks, parse_ok);
      id_len := 0;
      if not parse_ok or toks(toks'low).kind /= JSON_OBJECT then
        emit_error("ProtocolError", "malformed adapter command");
        return;
      end if;
      json_object_get(line_buf, toks, ntoks, toks'low, "id", id_tok, found);
      if found and toks(id_tok).kind = JSON_STRING then
        json_tok_get_str(line_buf, toks, id_tok, id_buf, id_len);
      end if;
      json_object_get(line_buf, toks, ntoks, toks'low, "op", op_tok, found);
      op_len := 0;
      if found and toks(op_tok).kind = JSON_STRING then
        json_tok_get_str(line_buf, toks, op_tok, op_buf, op_len);
      end if;

      if buf_eq_str(op_buf, 0, op_len, "hello") then
        version_ok := false;
        json_object_get(line_buf, toks, ntoks, toks'low, "protocolVersion", version_tok, found);
        if found then
          json_tok_as_int(line_buf, toks, version_tok, version_val, version_ok);
        end if;
        if not version_ok or version_val /= 1 then
          emit_error("ProtocolError", "unsupported adapter protocol version");
          return;
        end if;
        emit_ready;
      elsif buf_eq_str(op_buf, 0, op_len, "query") then
        handle_call("query", call_ok);
      elsif buf_eq_str(op_buf, 0, op_len, "mutation") then
        handle_call("mutation", call_ok);
      elsif buf_eq_str(op_buf, 0, op_len, "action") then
        handle_call("action", call_ok);
      elsif buf_eq_str(op_buf, 0, op_len, "setAuth") then
        ensure_client(client_ok);
        if client_ok then
          json_object_get(line_buf, toks, ntoks, toks'low, "token", token_tok, found);
          token_len := 0;
          if found and toks(token_tok).kind = JSON_STRING then
            json_tok_get_str(line_buf, toks, token_tok, token_buf, token_len);
          end if;
          auth_token_len := 0;
          buf_put_slice(auth_token, auth_token_len, token_buf, 0, token_len);
          emit_simple("ack");
        end if;
      elsif buf_eq_str(op_buf, 0, op_len, "subscribe") then
        ensure_client(client_ok);
        if client_ok then
          json_object_get(line_buf, toks, ntoks, toks'low, "subscriptionId", sub_id_tok, found);
          sub_id_len := 0;
          if found and toks(sub_id_tok).kind = JSON_STRING then
            json_tok_get_str(line_buf, toks, sub_id_tok, sub_id_buf, sub_id_len);
          end if;
          json_object_get(line_buf, toks, ntoks, toks'low, "path", path_tok, found);
          path_len := 0;
          if found and toks(path_tok).kind = JSON_STRING then
            json_tok_get_str(line_buf, toks, path_tok, path_buf, path_len);
          end if;
          json_object_get(line_buf, toks, ntoks, toks'low, "args", args_tok, found);
          args_len := 0;
          if found then
            buf_put_slice(args_buf, args_len, line_buf,
                           toks(args_tok).start, toks(args_tok).stop - toks(args_tok).start);
          else
            buf_put_str(args_buf, args_len, "{}");
          end if;
          sync_subscribe(xport_req, sm, string_of(sub_id_buf, sub_id_len), string_of(path_buf, path_len),
                          args_buf, args_len, sub_ok);
          if sub_ok then
            emit_simple("ack");
          else
            emit_error("ProtocolError", "subscribe failed");
          end if;
        end if;
      elsif buf_eq_str(op_buf, 0, op_len, "unsubscribe") then
        ensure_client(client_ok);
        if client_ok then
          json_object_get(line_buf, toks, ntoks, toks'low, "subscriptionId", sub_id_tok, found);
          sub_id_len := 0;
          if found and toks(sub_id_tok).kind = JSON_STRING then
            json_tok_get_str(line_buf, toks, sub_id_tok, sub_id_buf, sub_id_len);
          end if;
          sync_unsubscribe(xport_req, sm, string_of(sub_id_buf, sub_id_len), sub_ok);
          emit_simple("ack");
        end if;
      elsif buf_eq_str(op_buf, 0, op_len, "debugDisconnect") then
        ensure_client(client_ok);
        if client_ok then
          sync_debug_disconnect(xport_req, sm, sub_ok);
          if sub_ok then
            emit_simple("ack");
          else
            emit_error("ProtocolError", "no active Live connection");
          end if;
        end if;
      elsif buf_eq_str(op_buf, 0, op_len, "close") then
        emit_simple("closed");
        command_line_closed := true;
      else
        emit_error("ProtocolError", "unknown adapter operation");
      end if;
    end procedure handle_line;

    procedure drain_live_event is
      variable has_event : boolean;
      variable kind : sync_event_kind_t;
      variable sub_id : byte_array(0 to 63);
      variable sub_id_len : natural;
      variable value_json : byte_array(0 to 4095);
      variable value_len : natural;
      variable logs_json : byte_array(0 to 4095);
      variable logs_len : natural;
      variable err_name : byte_array(0 to 15);
      variable err_name_len : natural;
      variable err_message : byte_array(0 to 255);
      variable err_message_len : natural;
      variable step_ok : boolean;
    begin
      if not have_client then
        return;
      end if;
      sync_step(xport_req, sm, 50, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                logs_json, logs_len, err_name, err_name_len, err_message, err_message_len, step_ok);
      if not has_event then
        return;
      end if;
      if kind = SYNC_UPDATED then
        emit_subscription_value(sub_id, sub_id_len, value_json, value_len, logs_json, logs_len);
      else
        emit_subscription_error(sub_id, sub_id_len, err_name, err_name_len, err_message, err_message_len);
      end if;
    end procedure drain_live_event;

    -- === ADAPTER_LISTEN setup ===
    variable listen_addr : byte_array(0 to 63);
    variable listen_addr_len : natural;
    variable have_listen : boolean;
    variable colon_at : integer;
    variable listen_host : byte_array(0 to 63);
    variable listen_host_len : natural;
    variable listen_port_digits : byte_array(0 to 5);
    variable listen_port_ndig : natural;
    variable listen_port : integer;
    variable listen_rc : integer;
    variable accept_handle : integer;
    variable line_ok : boolean;
    variable ready : boolean;
  begin
    -- Matches the pinned toolchain vhdl/Dockerfile records to
    -- runtime-version and asserts with `ghdl --version`.
    buf_put_str(runtime_buf, runtime_len, "ghdl-2.0.0-llvm");

    getenv("ADAPTER_LISTEN", listen_addr, listen_addr_len, have_listen);
    if have_listen then
      colon_at := -1;
      for i in listen_addr_len - 1 downto 0 loop
        if listen_addr(i) = character'pos(':') then
          colon_at := i;
          exit;
        end if;
      end loop;
      assert colon_at >= 0 report "ADAPTER_LISTEN must be host:port" severity failure;
      listen_host_len := 0;
      buf_put_slice(listen_host, listen_host_len, listen_addr, 0, colon_at);
      listen_port_ndig := 0;
      for i in colon_at + 1 to listen_addr_len - 1 loop
        listen_port_digits(listen_port_ndig) := listen_addr(i) - character'pos('0');
        listen_port_ndig := listen_port_ndig + 1;
      end loop;
      listen_port := 0;
      for i in 0 to listen_port_ndig - 1 loop
        listen_port := listen_port * 10 + listen_port_digits(i);
      end loop;

      xport_call(xport_req, CMD_HOST_RESET, 0, 0, r);
      for i in 0 to listen_host_len - 1 loop
        xport_call(xport_req, CMD_HOST_PUSH, listen_host(i), 0, r);
      end loop;
      xport_call(xport_req, CMD_LISTEN, listen_port, 0, listen_rc);
      assert listen_rc = 0 report "could not listen on ADAPTER_LISTEN" severity failure;
      xport_call(xport_req, CMD_ACCEPT, 30000, 0, accept_handle);
      assert accept_handle >= 0 report "could not accept a connection on ADAPTER_LISTEN" severity failure;
      ctrl_handle := accept_handle;
      use_tcp := true;
    end if;

    loop
      exit when closed;
      check_input_ready(ready);
      if ready then
        read_input_line(line_ok);
        if not line_ok then
          closed := true;
        else
          handle_line(closed);
        end if;
      else
        drain_live_event;
      end if;
    end loop;

    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
