// convex.v - the public one-shot call facade this client's canonical
// example and the conformance adapter both use for query/mutation/action,
// plus Live subscriptions through an embedded convex_sync instance. This
// is the Verilog analogue of vhdl/client/convex.vhdl's client_call: it
// owns one convex_http instance for one-shot calls (a fresh connection
// per call, Connection: close, matching client/tests/http_smoke.v's own
// proven shape) and one convex_sync instance for /api/sync, and decodes
// the {status, value|errorMessage/errorData, logLines} envelope
// client/tests/http_smoke.v already proved the shape of into three
// module-level scratch strings a caller reads after every call() -
// the same "buffer/scratch is module state, never an argument or
// return value" discipline every other file in this client uses, for
// the identical toolchain reason (see convex_buffer.v's own header).
`timescale 1ns / 1ps
`include "client/convex_chars.vh"

module convex #(
  parameter MAX_SUBS = 8
);

  // convex_buffer.v's own KIND_STRING localparam (4), redeclared here
  // the same way client/tests/http_smoke.v and client/tests/json_test.v
  // redeclare its KIND_* constants - see convex_buffer.v's own header
  // for why a localparam is not meant to be a public constant.
  localparam KIND_STRING = 4;

  convex_http #(.REQ_CAP(16384), .HEADER_CAP(8192), .BODY_CAP(1048576), .BODY_TOK(2048)) http ();
  convex_sync #(.MAX_SUBS(MAX_SUBS)) sync ();
  convex_buffer #(.MAXLEN(1048576), .MAXTOK(2048)) call_body ();

  bit    configured;
  string auth_token;
  bit    has_auth_token;

  // Loop-accumulated scratch: module-level per the self-referential-
  // concatenation rule every other file in this client documents (see
  // convex_sync.v's raw_scratch/decoded_scratch header comment).
  string span_scratch;
  string decoded_scratch;
  string auth_header_scratch;

  // === results of the most recent call() ===============================
  // Raw (un-decoded) JSON text of the envelope's own "value" member on
  // success, or "" when the call failed - copied verbatim, not
  // re-encoded, so a caller (the adapter) can splice it straight into
  // its own output line exactly as convex_sync.v's sub_value_json does
  // for a Live update.
  string value_json;
  // Decoded text of "errorMessage" on a function-level failure.
  string error_message;
  bit    has_error_data;
  string error_data_json;
  // Raw JSON text of "logLines" (always an array, defaulting to "[]"
  // when the envelope omitted it), copied verbatim for the same reason
  // value_json is.
  string logs_json;

  initial begin
    configured = 1'b0;
    has_auth_token = 1'b0;
    auth_token = "";
  end

  task automatic configure(input string url, output bit ok);
    begin : main
      ok = 1'b0;
      http.parse_endpoint(url, ok);
      if (!ok) disable main;
      sync.configure(url);
      configured = 1'b1;
      ok = 1'b1;
    end
  endtask

  function automatic bit is_configured;
    return configured;
  endfunction

  task automatic set_auth(input string token);
    begin
      auth_token = token;
      has_auth_token = (token.len() > 0);
    end
  endtask

  task automatic clear_auth;
    begin
      auth_token = "";
      has_auth_token = 1'b0;
    end
  endtask

  // Copies buf's raw source bytes for tok (no escape decoding) into
  // span_scratch - the same helper convex_sync.v's capture_raw_span
  // provides for ws.msg, redeclared here for http.resp_body since
  // neither module can call into the other's private task (each
  // instance's tasks are only reachable hierarchically, and this
  // module has no reference to convex_sync.v's own instance-local
  // capture_raw_span).
  task automatic capture_value_span(input integer tok);
    integer i, start, stop;
    byte c;
    begin
      start = http.resp_body.tok_span_start(tok);
      stop = http.resp_body.tok_span_stop(tok);
      span_scratch = "";
      for (i = start; i < stop; i = i + 1) begin
        c = http.resp_body.get_byte(i);
        span_scratch = {span_scratch, c};
      end
    end
  endtask

  task automatic capture_error_message(input integer tok);
    byte b;
    bit done;
    begin
      http.resp_body.decode_str_start(tok);
      decoded_scratch = "";
      done = 1'b0;
      while (!done) begin
        http.resp_body.decode_str_next(b, done);
        if (!done) decoded_scratch = {decoded_scratch, b};
      end
    end
  endtask

  // One query/mutation/action round trip: POSTs {"path":path,
  // "args":args_json,"format":"json"} to /api/<op> over a fresh
  // connection (Connection: close), matching http_smoke.v's own proven
  // request shape exactly, then decodes the response envelope. ok is
  // false only for a transport-level failure (connect/send/read/non-200
  // HTTP status, or a body that did not parse as the expected envelope
  // shape) - a Convex function itself throwing is reported through
  // is_function_error=1 with ok still true, matching every peer
  // client's identical split between "the call could not be made" and
  // "the call was made and the function failed".
  task automatic call(
    input  string op,
    input  string path,
    input  string args_json,
    output bit    ok,
    output bit    is_function_error
  );
    integer status_tok, value_tok, errmsg_tok, errdata_tok, logs_tok;
    bit found, success, conn_ok, send_ok, read_ok;
    integer i;
    begin : main
      ok = 1'b0;
      is_function_error = 1'b0;
      value_json = "";
      error_message = "";
      has_error_data = 1'b0;
      error_data_json = "";
      logs_json = "[]";

      call_body.reset;
      call_body.put_byte("{");
      call_body.json_put_string("path");
      call_body.put_byte(":");
      call_body.json_put_string(path);
      call_body.put_byte(",");
      call_body.json_put_string("args");
      call_body.put_byte(":");
      if (args_json.len() > 0) call_body.put_str(args_json);
      else call_body.put_str("{}");
      call_body.put_byte(",");
      call_body.json_put_string("format");
      call_body.put_byte(":");
      call_body.json_put_string("json");
      call_body.put_byte("}");

      http.connect(conn_ok);
      if (!conn_ok) disable main;

      // hs.req (see convex_websocket.v's own identical comment on its
      // handshake request) is a plain append-only buffer: a second
      // call on this same http instance would otherwise start
      // appending this call's request line right after the previous
      // call's already-sent bytes.
      http.req.reset;
      if (op == "query") http.write_request_line("POST", "/api/query");
      else if (op == "mutation") http.write_request_line("POST", "/api/mutation");
      else http.write_request_line("POST", "/api/action");
      http.write_header("Host", http.ep_host);
      http.write_header("Content-Type", "application/json");
      if (has_auth_token) begin
        auth_header_scratch = {"Bearer ", auth_token};
        http.write_header("Authorization", auth_header_scratch);
      end
      http.write_header_int("Content-Length", call_body.length());
      http.write_header("Connection", "close");
      http.end_headers;
      for (i = 0; i < call_body.length(); i = i + 1) begin
        http.req.put_byte(call_body.get_byte(i));
      end

      http.send_request(send_ok);
      if (!send_ok) begin
        http.close;
        disable main;
      end
      http.read_response(15000, read_ok);
      http.close;
      if (!read_ok || http.status() != 200) disable main;

      http.resp_body.parse_json;
      if (!http.resp_body.json_ok()) disable main;
      http.resp_body.json_object_get(http.resp_body.json_root(), "status", status_tok, found);
      if (!found) disable main;
      http.resp_body.tok_eq_str(status_tok, "success", success);

      http.resp_body.json_object_get(http.resp_body.json_root(), "logLines", logs_tok, found);
      if (found) begin
        capture_value_span(logs_tok);
        logs_json = span_scratch;
      end

      if (success) begin
        http.resp_body.json_object_get(http.resp_body.json_root(), "value", value_tok, found);
        if (!found) disable main;
        capture_value_span(value_tok);
        value_json = span_scratch;
        is_function_error = 1'b0;
        ok = 1'b1;
      end else begin
        http.resp_body.json_object_get(http.resp_body.json_root(), "errorMessage", errmsg_tok, found);
        if (found && http.resp_body.json_kind(errmsg_tok) == KIND_STRING) begin
          capture_error_message(errmsg_tok);
          error_message = decoded_scratch;
        end else begin
          error_message = "Convex function failed";
        end
        http.resp_body.json_object_get(http.resp_body.json_root(), "errorData", errdata_tok, found);
        if (found) begin
          capture_value_span(errdata_tok);
          has_error_data = 1'b1;
          error_data_json = span_scratch;
        end
        is_function_error = 1'b1;
        ok = 1'b1;
      end
    end
  endtask

endmodule
