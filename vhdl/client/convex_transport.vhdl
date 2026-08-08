-- convex_transport.vhdl - the client expressed as a circuit.
--
-- This is a Convex client written as a simulated circuit rather than as
-- VHDL used procedurally with `wait` statements sprinkled through it.
-- Every program in this client (each test suite, the conformance
-- adapter, the canonical example) elaborates this entity exactly once
-- alongside its own driver process. Two concurrent, clocked processes
-- exist for as long as the program runs:
--
--   clock_gen  -- a free-running heartbeat that drives clk. It has no
--                 knowledge of Convex, HTTP, or even that a socket
--                 exists; it is a clock and nothing else.
--
--   transport  -- the sole owner of the foreign C boundary declared in
--                 convex_native.vhdl. On every rising edge of clk it
--                 checks whether cx_req has toggled since it last
--                 looked; if so, it performs exactly one C call, latches
--                 the result onto cx_result/cx_result_r, and toggles
--                 cx_ack to match, acknowledging the request.
--
-- Every other file in this client -- convex_buffer, convex_json,
-- convex_http, convex_ws, convex_sync, the adapter and the example --
-- is the driver side of that same handshake: a third process (declared
-- in whichever program is the current entry point) that calls
-- convex_native.xport_call, blocks on a genuine signal event (`wait
-- until cx_ack = cx_req`), and only then reads the answer. There is no
-- `wait for <n> ms;` anywhere in this client used as synchronization;
-- the only real-time waiting happens inside native.c's own poll(2)
-- calls, bounded by the timeout_ms each request carries, which is
-- exactly where AGENTS.md says a read deadline belongs -- on the layer
-- the bytes actually travel through, not a field a wrapper merely
-- consults.
--
-- clk's own period is a simulation heartbeat, not a wall-clock rate:
-- GHDL advances simulated time freely between requests, and a
-- transport call that blocks in native.c for real milliseconds does so
-- entirely inside one clocked step, exactly the way a hardware bus
-- transaction stalls the requesting side until the peripheral asserts
-- ready, without the clock itself needing to run at that peripheral's
-- real-world speed.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_native.all;

entity convex_transport is
end entity convex_transport;

architecture behav of convex_transport is
begin

  clock_gen : process is
  begin
    clk <= not clk;
    wait for 1 ns;
  end process clock_gen;

  xport_proc : process is
    variable last_req : std_logic := '0';
  begin
    wait until rising_edge(clk);
    if xport_req.req /= last_req then
      last_req := xport_req.req;
      xport_ack.result   <= cx_dispatch(xport_req.cmd, xport_req.a0, xport_req.a1);
      xport_ack.result_r <= cx_now_ms;
      xport_ack.ack      <= last_req;
    end if;
  end process xport_proc;

end architecture behav;
