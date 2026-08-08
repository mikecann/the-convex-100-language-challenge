// adapter.v - the NDJSON adapter protocol v1 executable. This is test
// infrastructure for the shared conformance harness, not part of the
// educational client API (AGENTS.md's "Conformance executable" section):
// it decodes one command per input line, calls the real client
// (client/convex.v for query/mutation/action and Live subscriptions),
// and encodes one event per output line. This is the Verilog analogue of
// vhdl/client/tests/conformance/adapter.vhdl - the same single-owner
// poll loop shape (peek whether a command is ready; if not, spend the
// tick draining Live instead), adapted to this toolchain's own
// "buffer/scratch is module state, reached hierarchically" discipline
// instead of VHDL's byte_array-by-reference procedures.
`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"
`include "client/convex_chars.vh"

module adapter;

  // Pinned exactly to verilog/Dockerfile's own toolchain assertion
  // (iverilog -V / dpkg-query), the same "hardcoded, kept in sync with
  // the Dockerfile" choice vhdl/client/tests/conformance/adapter.vhdl's
  // runtime_buf makes for ghdl-2.0.0-llvm.
  localparam ADAPTER_LANGUAGE       = "verilog";
  localparam ADAPTER_IMPLEMENTATION = "native-verilog-icarus-vpi-openssl";
  localparam ADAPTER_RUNTIME        = "iverilog-11.0-stable-debian-11.0-1.1+b1";

  // convex_buffer.v's own KIND_* localparams, redeclared per this
  // project's established convention (see client/convex.v's identical
  // redeclaration of KIND_STRING).
  localparam KIND_STRING = 4;
  localparam KIND_OBJECT = 6;

  convex_transport transport ();     // this adapter's OWN I/O opcodes only:
                                      // getenv, listen/accept, stdin/stdout,
                                      // wait_ready, exit - never touched by
                                      // conv.http/conv.sync, which each own
                                      // their own transport instance.
  convex #(.MAX_SUBS(8)) conv ();
  convex_buffer #(.MAXLEN(65536), .MAXTOK(1024)) cmdbuf ();  // one parsed input line
  convex_buffer #(.MAXLEN(1048576)) outbuf ();               // one built output line

  // === I/O mode: stdin/stdout, or one accepted ADAPTER_LISTEN connection ===
  bit     use_tcp;
  integer ctrl_handle;

  bit have_client;
  bit closed;

  // Byte-by-byte string equality - never a bare `a == b` on two
  // `string`s, whose support this project has not proven on this
  // toolchain (see convex_sync.v's identical str_eq and its own header
  // comment for why).
  function automatic bit str_eq(input string a, input string b);
    integer i;
    bit eq;
    begin
      eq = (a.len() == b.len());
      if (eq) begin
        for (i = 0; i < a.len(); i = i + 1) begin
          if (a[i] != b[i]) eq = 1'b0;
        end
      end
      str_eq = eq;
    end
  endfunction

  // Loop-accumulated scratch: module-level per the self-referential-
  // concatenation rule this whole client documents (see convex_http.v's
  // own header comment). Every string decoded out of cmdbuf below
  // targets one of these, never a task-local or output-port `string`.
  string id_str;
  string op_str;
  string path_str;
  string args_str;
  string sub_id_str;
  string token_str;
  string decode_scratch;
  string env_scratch;
  string listen_host_scratch;
  string listen_port_scratch;

  // === Live delivery: a bounded, single-slot-per-subscription mailbox,
  // not a growing queue ===================================================
  //
  // AGENTS.md's "Conformance executable" section requires a
  // deliberately bounded buffering choice for Live delivery, tested
  // under a stopped reader. client/convex_sync.v already stores at most
  // one CURRENT value per active subscription (sub_value_json/
  // sub_error_msg, overwritten in place, never a per-update history -
  // see that file's own header comment on this deliberate scope
  // choice); this adapter's own "queue" is therefore just a fixed
  // MAX_SUBS-sized array of "have I emitted the CURRENT version yet"
  // flags, one per conv.sync subscription slot. No matter how many
  // Transitions arrive while stdout is not being drained (a stopped
  // reader), conv.sync's own state never grows past its one slot per
  // subscription, and this array never grows past MAX_SUBS entries - a
  // fixed, provable byte budget of MAX_SUBS * (one value's worth of
  // text), far under the shared 128 MiB limit, satisfying the
  // requirement with a mailbox rather than a ring buffer. Proven under
  // an actual stopped reader (a real blocked stdout pipe, thousands of
  // unpaced Live updates, and a peak-VmRSS assertion, not only a static
  // argument) by verilog/Dockerfile's own Scenario D, since the proof
  // needs a real OS pipe and a real subprocess to hold unread, which a
  // plain simulation testbench like this client's other tests cannot
  // set up on its own.
  localparam MAX_SUBS = 8;
  integer last_emitted_version [0:MAX_SUBS-1];

  initial begin
    use_tcp = 1'b0;
    ctrl_handle = -1;
    have_client = 1'b0;
    closed = 1'b0;
  end

  // === I/O primitives: every other task below reads/writes through
  // exactly these, so the stdin/stdout-vs-socket choice is made once. ===

  task automatic read_input_line(output bit ok);
    integer bb;
    begin : main
      cmdbuf.reset;
      ok = 1'b0;
      while (1'b1) begin
        if (use_tcp) transport.xport_call(`CMD_READ_BYTE, ctrl_handle, 60000, bb);
        else transport.xport_call(`CMD_STDIN_READ_BYTE, 60000, 0, bb);
        if (bb < 0) disable main; // EOF, timeout, or transport error
        if (bb == `LF) begin
          ok = 1'b1;
          disable main;
        end
        if (bb != `CR) cmdbuf.put_byte(bb[7:0]);
      end
    end
  endtask

  // A zero-timeout peek: true when a command byte is ready right now,
  // used to decide each loop tick whether to read a command or spend the
  // tick draining Live instead.
  task automatic check_input_ready(output bit ready);
    integer m;
    begin
      if (use_tcp) transport.xport_call(`CMD_WAIT_READY, ctrl_handle, 0, m);
      else transport.xport_call(`CMD_WAIT_READY_STDIN, -1, 0, m);
      ready = (m != 0);
    end
  endtask

  task automatic emit_line;
    integer i, r;
    begin
      outbuf.put_byte(`LF);
      if (use_tcp) begin
        for (i = 0; i < outbuf.length(); i = i + 1) begin
          transport.xport_call(`CMD_WRITE_BYTE, ctrl_handle, outbuf.get_byte(i), r);
        end
        transport.xport_call(`CMD_WRITE_FLUSH, ctrl_handle, 0, r);
      end else begin
        for (i = 0; i < outbuf.length(); i = i + 1) begin
          transport.xport_call(`CMD_STDOUT_WRITE_BYTE, outbuf.get_byte(i), 0, r);
        end
        transport.xport_call(`CMD_STDOUT_FLUSH, 0, 0, r);
      end
    end
  endtask

  task automatic getenv(input string name, output bit found);
    integer i, r, lookup_len;
    byte eb;
    begin : main
      found = 1'b0;
      env_scratch = "";
      transport.xport_call(`CMD_GETENV_RESET, 0, 0, r);
      for (i = 0; i < name.len(); i = i + 1) begin
        transport.xport_call(`CMD_GETENV_PUSH, name[i], 0, r);
      end
      transport.xport_call(`CMD_GETENV_LOOKUP, 0, 0, lookup_len);
      if (lookup_len < 0) disable main;
      found = 1'b1;
      for (i = 0; i < lookup_len; i = i + 1) begin
        transport.xport_call(`CMD_GETENV_BYTE, i, 0, r);
        eb = r[7:0];
        env_scratch = {env_scratch, eb};
      end
    end
  endtask

  // === decoding helpers over cmdbuf ====================================

  task automatic decode_field_string(input integer tok, output string s);
    byte b;
    bit done;
    begin
      cmdbuf.decode_str_start(tok);
      decode_scratch = "";
      done = 1'b0;
      while (!done) begin
        cmdbuf.decode_str_next(b, done);
        if (!done) decode_scratch = {decode_scratch, b};
      end
      s = decode_scratch;
    end
  endtask

  // Raw (un-decoded) JSON span of tok within cmdbuf, for the "args"
  // member - an object this adapter must forward verbatim, not decode.
  task automatic capture_cmd_span(input integer tok, output string s);
    integer i, start, stop;
    byte c;
    begin
      start = cmdbuf.tok_span_start(tok);
      stop = cmdbuf.tok_span_stop(tok);
      decode_scratch = "";
      for (i = start; i < stop; i = i + 1) begin
        c = cmdbuf.get_byte(i);
        decode_scratch = {decode_scratch, c};
      end
      s = decode_scratch;
    end
  endtask

  // === event encoding ====================================================

  task automatic emit_ready;
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("protocolVersion"); outbuf.put_byte(":"); outbuf.json_put_int(1);
      outbuf.put_byte(",");
      outbuf.json_put_string("id"); outbuf.put_byte(":"); outbuf.json_put_string(id_str);
      outbuf.put_byte(",");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string("ready");
      outbuf.put_byte(",");
      outbuf.json_put_string("language"); outbuf.put_byte(":"); outbuf.json_put_string(ADAPTER_LANGUAGE);
      outbuf.put_byte(",");
      outbuf.json_put_string("implementation"); outbuf.put_byte(":");
      outbuf.json_put_string(ADAPTER_IMPLEMENTATION);
      outbuf.put_byte(",");
      outbuf.json_put_string("runtime"); outbuf.put_byte(":"); outbuf.json_put_string(ADAPTER_RUNTIME);
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  task automatic emit_simple(input string kind);
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("id"); outbuf.put_byte(":"); outbuf.json_put_string(id_str);
      outbuf.put_byte(",");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string(kind);
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  task automatic emit_error(input string name, input string message);
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("id"); outbuf.put_byte(":"); outbuf.json_put_string(id_str);
      outbuf.put_byte(",");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string("error");
      outbuf.put_byte(",");
      outbuf.json_put_string("error"); outbuf.put_byte(":");
      outbuf.put_byte("{");
      outbuf.json_put_string("name"); outbuf.put_byte(":"); outbuf.json_put_string(name);
      outbuf.put_byte(",");
      outbuf.json_put_string("message"); outbuf.put_byte(":"); outbuf.json_put_string(message);
      outbuf.put_byte("}");
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  // A successful query/mutation/action: value_json is raw (already
  // valid JSON) text, spliced straight in, matching the "copy the exact
  // source bytes" rule conv.value_json's own capture already applied.
  task automatic emit_result;
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("id"); outbuf.put_byte(":"); outbuf.json_put_string(id_str);
      outbuf.put_byte(",");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string("result");
      outbuf.put_byte(",");
      outbuf.json_put_string("value"); outbuf.put_byte(":"); outbuf.put_str(conv.value_json);
      outbuf.put_byte(",");
      outbuf.json_put_string("logs"); outbuf.put_byte(":"); outbuf.put_str(conv.logs_json);
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  // A function-level failure from a one-shot call: name is always
  // "FunctionError", matching vhdl/client/tests/conformance/adapter.vhdl's
  // identical choice (the required conformance tests only assert
  // error.data.code, never error.name).
  task automatic emit_call_function_error;
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("id"); outbuf.put_byte(":"); outbuf.json_put_string(id_str);
      outbuf.put_byte(",");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string("error");
      outbuf.put_byte(",");
      outbuf.json_put_string("error"); outbuf.put_byte(":");
      outbuf.put_byte("{");
      outbuf.json_put_string("name"); outbuf.put_byte(":"); outbuf.json_put_string("FunctionError");
      outbuf.put_byte(",");
      outbuf.json_put_string("message"); outbuf.put_byte(":"); outbuf.json_put_string(conv.error_message);
      if (conv.has_error_data) begin
        outbuf.put_byte(",");
        outbuf.json_put_string("data"); outbuf.put_byte(":"); outbuf.put_str(conv.error_data_json);
      end
      outbuf.put_byte("}");
      outbuf.put_byte(",");
      outbuf.json_put_string("logs"); outbuf.put_byte(":"); outbuf.put_str(conv.logs_json);
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  task automatic emit_subscription_value(input string sid, input string value_json);
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string("subscription");
      outbuf.put_byte(",");
      outbuf.json_put_string("subscriptionId"); outbuf.put_byte(":"); outbuf.json_put_string(sid);
      outbuf.put_byte(",");
      outbuf.json_put_string("value"); outbuf.put_byte(":"); outbuf.put_str(value_json);
      outbuf.put_byte(",");
      outbuf.json_put_string("logs"); outbuf.put_byte(":"); outbuf.put_str("[]");
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  task automatic emit_subscription_error(
    input string sid,
    input string message,
    input bit    has_data,
    input string data_json
  );
    begin
      outbuf.reset;
      outbuf.put_byte("{");
      outbuf.json_put_string("type"); outbuf.put_byte(":"); outbuf.json_put_string("subscription");
      outbuf.put_byte(",");
      outbuf.json_put_string("subscriptionId"); outbuf.put_byte(":"); outbuf.json_put_string(sid);
      outbuf.put_byte(",");
      outbuf.json_put_string("error"); outbuf.put_byte(":");
      outbuf.put_byte("{");
      outbuf.json_put_string("name"); outbuf.put_byte(":"); outbuf.json_put_string("FunctionError");
      outbuf.put_byte(",");
      outbuf.json_put_string("message"); outbuf.put_byte(":"); outbuf.json_put_string(message);
      if (has_data) begin
        outbuf.put_byte(",");
        outbuf.json_put_string("data"); outbuf.put_byte(":"); outbuf.put_str(data_json);
      end
      outbuf.put_byte("}");
      outbuf.put_byte("}");
      emit_line;
    end
  endtask

  // === command handling ==================================================

  task automatic ensure_client(output bit ok);
    bit found, cfg_ok;
    begin : main
      if (have_client) begin
        ok = 1'b1;
        disable main;
      end
      getenv("CONVEX_URL", found);
      if (!found || env_scratch.len() == 0) begin
        emit_error("ProtocolError", "CONVEX_URL is required");
        ok = 1'b0;
        disable main;
      end
      conv.configure(env_scratch, cfg_ok);
      if (!cfg_ok) begin
        emit_error("ProtocolError", "CONVEX_URL is not a valid deployment URL");
        ok = 1'b0;
        disable main;
      end
      have_client = 1'b1;
      ok = 1'b1;
    end
  endtask

  task automatic handle_call(input string op);
    bit client_ok, call_ok, is_fn_err;
    integer path_tok, args_tok;
    bit found;
    begin : main
      ensure_client(client_ok);
      if (!client_ok) disable main;

      cmdbuf.json_object_get(cmdbuf.json_root(), "path", path_tok, found);
      path_str = "";
      if (found && cmdbuf.json_kind(path_tok) == KIND_STRING) decode_field_string(path_tok, path_str);

      cmdbuf.json_object_get(cmdbuf.json_root(), "args", args_tok, found);
      if (found) capture_cmd_span(args_tok, args_str);
      else args_str = "{}";

      conv.call(op, path_str, args_str, call_ok, is_fn_err);
      if (!call_ok) begin
        emit_error("TransportError", "the call failed");
        disable main;
      end
      if (is_fn_err) emit_call_function_error;
      else emit_result;
    end
  endtask

  task automatic handle_line;
    integer id_tok, op_tok, sub_id_tok, path_tok, args_tok, token_tok, version_tok;
    bit found, version_ok, client_ok, sub_ok;
    integer version_val;
    integer idx;
    begin : main
      cmdbuf.parse_json;
      id_str = "";
      if (!cmdbuf.json_ok() || cmdbuf.json_kind(cmdbuf.json_root()) != KIND_OBJECT) begin
        emit_error("ProtocolError", "malformed adapter command");
        disable main;
      end

      cmdbuf.json_object_get(cmdbuf.json_root(), "id", id_tok, found);
      if (found && cmdbuf.json_kind(id_tok) == KIND_STRING) decode_field_string(id_tok, id_str);

      cmdbuf.json_object_get(cmdbuf.json_root(), "op", op_tok, found);
      op_str = "";
      if (found && cmdbuf.json_kind(op_tok) == KIND_STRING) decode_field_string(op_tok, op_str);

      if (str_eq(op_str, "hello")) begin
        version_ok = 1'b0;
        cmdbuf.json_object_get(cmdbuf.json_root(), "protocolVersion", version_tok, found);
        if (found) cmdbuf.tok_as_int(version_tok, version_val, version_ok);
        if (!version_ok || version_val != 1) begin
          emit_error("ProtocolError", "unsupported adapter protocol version");
          disable main;
        end
        emit_ready;
      end else if (str_eq(op_str, "query")) begin
        handle_call("query");
      end else if (str_eq(op_str, "mutation")) begin
        handle_call("mutation");
      end else if (str_eq(op_str, "action")) begin
        handle_call("action");
      end else if (str_eq(op_str, "setAuth")) begin
        ensure_client(client_ok);
        if (client_ok) begin
          cmdbuf.json_object_get(cmdbuf.json_root(), "token", token_tok, found);
          token_str = "";
          if (found && cmdbuf.json_kind(token_tok) == KIND_STRING) decode_field_string(token_tok, token_str);
          if (token_str.len() > 0) conv.set_auth(token_str);
          else conv.clear_auth;
          emit_simple("ack");
        end
      end else if (str_eq(op_str, "subscribe")) begin
        ensure_client(client_ok);
        if (client_ok) begin
          cmdbuf.json_object_get(cmdbuf.json_root(), "subscriptionId", sub_id_tok, found);
          sub_id_str = "";
          if (found && cmdbuf.json_kind(sub_id_tok) == KIND_STRING) decode_field_string(sub_id_tok, sub_id_str);
          cmdbuf.json_object_get(cmdbuf.json_root(), "path", path_tok, found);
          path_str = "";
          if (found && cmdbuf.json_kind(path_tok) == KIND_STRING) decode_field_string(path_tok, path_str);
          cmdbuf.json_object_get(cmdbuf.json_root(), "args", args_tok, found);
          if (found) capture_cmd_span(args_tok, args_str);
          else args_str = "{}";

          conv.sync.add_subscription(sub_id_str, path_str, args_str, sub_ok);
          if (sub_ok) begin
            idx = conv.sync.find_sub_by_tag(sub_id_str);
            if (idx >= 0) last_emitted_version[idx] = 0;
            emit_simple("ack");
          end else begin
            emit_error("ProtocolError", "subscribe failed");
          end
        end
      end else if (str_eq(op_str, "unsubscribe")) begin
        ensure_client(client_ok);
        if (client_ok) begin
          cmdbuf.json_object_get(cmdbuf.json_root(), "subscriptionId", sub_id_tok, found);
          sub_id_str = "";
          if (found && cmdbuf.json_kind(sub_id_tok) == KIND_STRING) decode_field_string(sub_id_tok, sub_id_str);
          conv.sync.remove_subscription(sub_id_str, sub_ok);
          emit_simple("ack");
        end
      end else if (str_eq(op_str, "debugDisconnect")) begin
        ensure_client(client_ok);
        if (client_ok) begin
          conv.sync.force_disconnect;
          emit_simple("ack");
        end
      end else if (str_eq(op_str, "close")) begin
        emit_simple("closed");
        closed = 1'b1;
      end else begin
        emit_error("ProtocolError", "unknown adapter operation");
      end
    end
  endtask

  // One idle-tick's worth of Live work: gives a dropped connection a
  // chance to reconnect and receives at most one message (conv.sync.pump
  // itself is already bounded to a short timeout), then scans every
  // active subscription slot for a version this adapter has not emitted
  // yet - see this file's own header comment on why that scan, not a
  // growing queue, is this adapter's whole Live-delivery buffering
  // story.
  task automatic drain_live_events;
    integer i;
    bit got;
    begin : main
      if (!have_client) disable main;
      conv.sync.pump(50, got);
      for (i = 0; i < MAX_SUBS; i = i + 1) begin
        if (conv.sync.sub_active[i] && conv.sync.sub_version[i] != last_emitted_version[i]) begin
          last_emitted_version[i] = conv.sync.sub_version[i];
          if (conv.sync.sub_is_error[i]) begin
            emit_subscription_error(
              conv.sync.sub_tag[i], conv.sync.sub_error_msg[i],
              conv.sync.sub_has_error_data[i], conv.sync.sub_error_data_json[i]
            );
          end else begin
            emit_subscription_value(conv.sync.sub_tag[i], conv.sync.sub_value_json[i]);
          end
        end
      end
    end
  endtask

  // === ADAPTER_LISTEN setup, then the main command loop =================

  integer i_init;
  bit have_listen;
  integer colon_at, listen_port, listen_rc, accept_handle, r;
  bit line_ok, ready;

  initial begin
    for (i_init = 0; i_init < MAX_SUBS; i_init = i_init + 1) begin
      last_emitted_version[i_init] = 0;
    end

    getenv("ADAPTER_LISTEN", have_listen);
    if (have_listen) begin
      colon_at = -1;
      for (i_init = env_scratch.len() - 1; i_init >= 0; i_init = i_init - 1) begin
        if (colon_at < 0 && env_scratch[i_init] == ":") colon_at = i_init;
      end
      if (colon_at < 0) begin
        $display("FATAL adapter: ADAPTER_LISTEN must be host:port");
        $finish;
      end
      listen_host_scratch = env_scratch.substr(0, colon_at - 1);
      listen_port_scratch = env_scratch.substr(colon_at + 1, env_scratch.len() - 1);
      listen_port = 0;
      for (i_init = 0; i_init < listen_port_scratch.len(); i_init = i_init + 1) begin
        listen_port = listen_port * 10 + (listen_port_scratch[i_init] - "0");
      end

      transport.xport_call(`CMD_HOST_RESET, 0, 0, r);
      for (i_init = 0; i_init < listen_host_scratch.len(); i_init = i_init + 1) begin
        transport.xport_call(`CMD_HOST_PUSH, listen_host_scratch[i_init], 0, r);
      end
      transport.xport_call(`CMD_LISTEN, listen_port, 0, listen_rc);
      if (listen_rc != 0) begin
        $display("FATAL adapter: could not listen on ADAPTER_LISTEN (%s)", env_scratch);
        $finish;
      end
      transport.xport_call(`CMD_ACCEPT, 30000, 0, accept_handle);
      if (accept_handle < 0) begin
        $display("FATAL adapter: no controller connected on ADAPTER_LISTEN within 30s");
        $finish;
      end
      ctrl_handle = accept_handle;
      use_tcp = 1'b1;
    end

    while (!closed) begin
      check_input_ready(ready);
      if (ready) begin
        read_input_line(line_ok);
        if (!line_ok) closed = 1'b1;
        else handle_line;
      end else begin
        drain_live_events;
      end
    end

    transport.xport_call(`CMD_EXIT, 0, 0, r);
  end

endmodule
