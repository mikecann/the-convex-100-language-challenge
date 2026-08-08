// http_smoke.v - gate proof: a real HTTP/1.1 POST /api/query round trip
// against the approved test deployment, driven entirely through
// convex_http.v's request/response framing and convex_buffer.v's JSON
// encode/decode - proving those two layers actually work together
// against the real backend, not just that they compile.
//
// This calls the shared demo module's read-only demo:state query for a
// scratch room, the same query every other language's canonical example
// reads first (see e.g. harbour/client/convexhttp.prg). Only the
// envelope shape (status/value/errorMessage/logLines) and this query's
// own "count" field are asserted here; this is not the canonical example
// itself - that needs the RFC 6455 WebSocket Live layer this client does
// not have yet (see verilog/manifest.yaml).

`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"
`include "client/convex_chars.vh"

module http_smoke;

  // KIND_OBJECT's value (6) is convex_buffer.v's own localparam; this
  // test compares against the literal the same way json_test.v does for
  // KIND_BOOL, since a localparam is not meant to be a public constant.
  localparam KIND_OBJECT = 6;

  convex_http #(.REQ_CAP(4096), .HEADER_CAP(4096), .BODY_CAP(65536)) client ();
  convex_buffer #(.MAXLEN(512)) body ();

  integer failed;
  bit ok;
  integer i;
  integer status_tok, value_tok, count_tok;
  bit found;
  integer count_val;

  initial begin
    failed = 0;

    // Build the request body: {"path":"demo:state","args":{"room":"..."},"format":"json"}
    body.reset;
    body.put_byte("{");
    body.json_put_string("path");
    body.put_byte(":");
    body.json_put_string("demo:state");
    body.put_byte(",");
    body.json_put_string("args");
    body.put_byte(":");
    body.put_byte("{");
    body.json_put_string("room");
    body.put_byte(":");
    body.json_put_string("verilog-http-smoke");
    body.put_byte("}");
    body.put_byte(",");
    body.json_put_string("format");
    body.put_byte(":");
    body.json_put_string("json");
    body.put_byte("}");

    client.parse_endpoint("https://usable-reindeer-44.convex.cloud", ok);
    if (!ok) begin
      $display("FAIL http_smoke: parse_endpoint rejected the deployment URL");
      $finish;
    end

    client.connect(ok);
    if (!ok) begin
      $display("FAIL http_smoke: connect failed, handle=%0d", client.handle);
      $finish;
    end
    $display("http_smoke: connected (TLS verified), handle=%0d", client.handle);

    client.write_request_line("POST", "/api/query");
    client.write_header("Host", "usable-reindeer-44.convex.cloud");
    client.write_header("Content-Type", "application/json");
    client.write_header_int("Content-Length", body.length());
    client.write_header("Connection", "close");
    client.end_headers;
    for (i = 0; i < body.length(); i = i + 1) begin
      client.req.put_byte(body.get_byte(i));
    end

    client.send_request(ok);
    if (!ok) begin
      $display("FAIL http_smoke: send_request failed");
      $finish;
    end

    client.read_response(15000, ok);
    if (!ok) begin
      $display("FAIL http_smoke: read_response failed or timed out");
      $finish;
    end
    $display("http_smoke: HTTP status %0d, body %0d bytes",
              client.status(), client.resp_body.length());

    if (client.status() != 200) begin
      $display("FAIL http_smoke: expected HTTP 200, got %0d", client.status());
      $finish;
    end

    client.resp_body.parse_json;
    if (!client.resp_body.json_ok()) begin
      $display("FAIL http_smoke: response body did not parse as JSON");
      $finish;
    end

    client.resp_body.json_object_get(client.resp_body.json_root(), "status", status_tok, found);
    if (!found) begin
      $display("FAIL http_smoke: envelope had no \"status\" field");
      failed = 1;
    end else begin
      client.resp_body.tok_eq_str(status_tok, "success", ok);
      if (!ok) begin
        $display("FAIL http_smoke: envelope status was not \"success\"");
        failed = 1;
      end
    end

    if (!failed) begin
      client.resp_body.json_object_get(client.resp_body.json_root(), "value", value_tok, found);
      if (!found || client.resp_body.json_kind(value_tok) != KIND_OBJECT) begin
        $display("FAIL http_smoke: envelope \"value\" was missing or not an object");
        failed = 1;
      end else begin
        client.resp_body.json_object_get(value_tok, "count", count_tok, found);
        if (!found) begin
          $display("FAIL http_smoke: demo:state value had no \"count\" field");
          failed = 1;
        end else begin
          client.resp_body.tok_as_int(count_tok, count_val, ok);
          if (!ok || count_val < 0) begin
            $display("FAIL http_smoke: \"count\" was not a valid non-negative integer");
            failed = 1;
          end else begin
            $display("http_smoke: demo:state count = %0d", count_val);
          end
        end
      end
    end

    client.close;

    if (failed == 0) begin
      $display("PASS http_smoke");
    end else begin
      $display("FAIL http_smoke");
    end
    $finish;
  end

endmodule
