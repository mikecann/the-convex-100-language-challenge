// convex_transport.v - the client's foreign boundary expressed as a circuit.
//
// This is the Verilog analogue of vhdl/client/convex_transport.vhdl on
// branch codex/vhdl-client: a clocked request/acknowledge bus that owns
// the only calls this client ever makes into native.c's VPI module. Every
// other file in this client reaches sockets, TLS, stdout or the clock by
// invoking this module's xport_call task - never $cx_dispatch directly.
//
// Two things run for as long as any program built on this module runs:
//
//   an always block   - a free-running clock (clk), a simulation
//                        heartbeat with no knowledge of Convex, HTTP, or
//                        even that a socket exists.
//
//   an always block   - the transport process. On every rising edge of
//                        clk it checks whether req has toggled since it
//                        last looked; if so, it performs exactly one call
//                        into native.c through $cx_dispatch, latches the
//                        result, and toggles ack to match, acknowledging
//                        the request.
//
// A calling process (a test, the conformance adapter, the canonical
// example) invokes the `xport_call` task by hierarchical reference, e.g.
// `transport.xport_call(CMD_CONNECT, 443, 1, handle);`. That task flips
// req and then executes a genuine blocking `wait (ack == req);` - a real
// signal-level wait, not a `#delay` used as synchronization. There is no
// `#<n>` anywhere in this client used to wait for an answer; the only
// real-time waiting happens inside native.c's own poll(2) calls, bounded
// by the timeout_ms each request carries.
//
// clk's own period is a simulation heartbeat, not a wall-clock rate:
// Icarus advances simulated time freely between requests, and a
// transport call that blocks in native.c for real milliseconds does so
// entirely inside one clocked step, exactly the way a hardware bus
// transaction stalls the requesting side until the peripheral asserts
// ready, without the clock itself needing to run at that peripheral's
// real-world speed.

`timescale 1ns / 1ps

module convex_transport;

  reg clk = 1'b0;
  always #1 clk = ~clk;

  reg                req = 1'b0;
  reg                ack = 1'b0;
  reg signed [31:0]  cmd_r = 0;
  reg signed [31:0]  a0_r = 0;
  reg signed [31:0]  a1_r = 0;
  reg signed [31:0]  result_r = 0;
  real               result_time_r = 0.0;

  always @(posedge clk) begin
    if (req !== ack) begin
      result_r      <= $cx_dispatch(cmd_r, a0_r, a1_r);
      result_time_r <= $cx_now_ms;
      ack           <= req;
    end
  end

  // The sole entry point every other file in this client uses to reach
  // native.c. `automatic` gives each call its own local `result` binding
  // even though a second call cannot really overlap the first here (this
  // module has only one req/ack pair - callers queue behind each other
  // the same way a real bus arbitrates one transaction at a time).
  task automatic xport_call;
    input  signed [31:0] cmd;
    input  signed [31:0] a0;
    input  signed [31:0] a1;
    output signed [31:0] result;
    begin
      cmd_r = cmd;
      a0_r  = a0;
      a1_r  = a1;
      req   = ~req;
      wait (ack == req);
      result = result_r;
    end
  endtask

  // The wall-clock time (native.c's CLOCK_MONOTONIC, milliseconds) as
  // of the most recently completed xport_call, for a caller that needs
  // a timestamp for scheduling (convex_sync.v's reconnect backoff)
  // without itself calling $cx_now_ms - this file stays the only
  // Verilog file that calls either system function, per its own header
  // comment. A caller that needs a genuinely fresh timestamp rather
  // than "as of the last bus transaction" issues a cheap CMD_NOP
  // xport_call immediately first; result_time_r updates on every
  // dispatch, not just ones a caller cares about the return value of.
  function automatic real now_ms;
    return result_time_r;
  endfunction

endmodule
