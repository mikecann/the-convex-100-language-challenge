// convex_test.v - gate proof for client/convex.v's call() facade against
// the approved test deployment: a successful query (demo:state), a
// successful mutation (demo:increment), and a function-level failure
// with structured errorData (demo:fail) - the same three shapes
// client/tests/conformance/adapter.v relies on this module for, proven
// once here independently of the adapter's own NDJSON framing.

`timescale 1ns / 1ps
`include "client/convex_chars.vh"

module convex_test;

  convex #(.MAX_SUBS(2)) conv ();

  // A small local JSON-args builder, since a raw `string` literal on
  // this toolchain cannot spell a literal `"` byte (see
  // convex_chars.vh's own header for the confirmed `\"`-expansion bug);
  // every args object below is built through this buffer instead of a
  // hand-quoted string literal.
  convex_buffer #(.MAXLEN(256)) args ();

  integer failed;
  bit ok, is_fn_err, cfg_ok;
  string room;
  string args_str;
  string run_id;
  integer i;
  byte c;

  // Copies args' own bytes into the module-level args_str. Targets
  // module state, not a task-local or output-port `string`, per the
  // self-referential-concatenation rule every other file in this client
  // documents (see convex_http.v's own header comment).
  task automatic buf_to_args_str;
    begin
      args_str = "";
      for (i = 0; i < args.length(); i = i + 1) begin
        c = args.get_byte(i);
        args_str = {args_str, c};
      end
    end
  endtask

  initial begin
    failed = 0;

    conv.configure("https://usable-reindeer-44.convex.cloud", cfg_ok);
    if (!cfg_ok) begin
      $display("FAIL convex_test: configure rejected the deployment URL");
      $finish;
    end

    room = "verilog-convex-facade-test";

    // A successful query: demo:state on a fresh room reports count 0.
    args.reset;
    args.put_byte("{");
    args.json_put_string("room");
    args.put_byte(":");
    args.json_put_string(room);
    args.put_byte("}");
    buf_to_args_str;
    conv.call("query", "demo:state", args_str, ok, is_fn_err);
    if (!ok || is_fn_err) begin
      $display("FAIL convex_test: demo:state query failed (ok=%b is_fn_err=%b)", ok, is_fn_err);
      failed = 1;
    end else if (conv.value_json.len() == 0) begin
      $display("FAIL convex_test: demo:state returned no value");
      failed = 1;
    end else begin
      $display("convex_test: demo:state query OK, value=%s", conv.value_json);
    end

    // A successful mutation: demo:increment applies and reports count 1.
    args.reset;
    args.put_byte("{");
    args.json_put_string("room");
    args.put_byte(":");
    args.json_put_string(room);
    args.put_byte(",");
    args.json_put_string("language");
    args.put_byte(":");
    args.json_put_string("Verilog");
    args.put_byte(",");
    args.json_put_string("runId");
    args.put_byte(":");
    run_id = {room, "-once"};
    args.json_put_string(run_id);
    args.put_byte("}");
    buf_to_args_str;
    conv.call("mutation", "demo:increment", args_str, ok, is_fn_err);
    if (!ok || is_fn_err) begin
      $display("FAIL convex_test: demo:increment mutation failed (ok=%b is_fn_err=%b)", ok, is_fn_err);
      failed = 1;
    end else begin
      $display("convex_test: demo:increment mutation OK, value=%s", conv.value_json);
    end

    // A function-level failure with structured errorData: demo:fail
    // always throws, carrying {"code": "<the code argument>"} as its
    // errorData - the same field the adapter's structured-error and
    // query-error-recovery conformance tests both assert on.
    args.reset;
    args.put_byte("{");
    args.json_put_string("code");
    args.put_byte(":");
    args.json_put_string("VERILOG_FACADE_TEST");
    args.put_byte("}");
    buf_to_args_str;
    conv.call("query", "demo:fail", args_str, ok, is_fn_err);
    if (!ok || !is_fn_err) begin
      $display("FAIL convex_test: demo:fail did not report as a function error (ok=%b is_fn_err=%b)", ok, is_fn_err);
      failed = 1;
    end else if (!conv.has_error_data || conv.error_data_json.len() == 0) begin
      $display("FAIL convex_test: demo:fail reported no errorData");
      failed = 1;
    end else begin
      $display("convex_test: demo:fail OK, errorMessage=%s errorData=%s", conv.error_message, conv.error_data_json);
    end

    if (failed == 0) begin
      $display("PASS convex_test");
    end else begin
      $display("FAIL convex_test");
    end
    $finish;
  end

endmodule
