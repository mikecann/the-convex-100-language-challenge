-- convex_native.vhdl - the shared bus signal and the foreign boundary.
--
-- Standard VHDL has no sockets, no TLS, no monotonic clock, no entropy
-- source and no environment access. client/native.c supplies exactly
-- those, as two VHPIDIRECT-callable C functions with scalar-only
-- signatures (see native.c's header comment for why). This package
-- declares those two functions and the clocked request/acknowledge bus
-- that connects them to the rest of the client: convex_transport.vhdl's
-- transport process is the only code anywhere in this client that calls
-- either function, and everything else -- HTTP/1.1, JSON, RFC 6455
-- WebSocket framing and the Convex sync protocol -- reaches the outside
-- world only by driving the bus's req field and reading its result once
-- ack catches up.
--
-- The whole bus is one signal, xport_bus, of the record type declared
-- below. VHDL forbids a subprogram from assigning to a signal that is
-- not one of its own signal-class formal parameters (the driver a
-- signal assignment creates has to be attributable to a single,
-- statically known process, and an arbitrary package-level global would
-- break that), so xport_call below takes the bus as an explicit `signal
-- ... inout` parameter. Every call site passes the one real xport_bus
-- signal declared here, so the record still behaves like a genuine
-- shared bus -- one wire, driven by whichever of the two processes on
-- either end of it currently owns the transaction -- and not a
-- per-caller copy.
library ieee;
use ieee.std_logic_1164.all;

package convex_native is

  -- Opcodes dispatched through cx_dispatch. Kept in sync with the CMD_*
  -- enum in native.c.
  constant CMD_NOP               : integer := 0;
  constant CMD_HOST_RESET        : integer := 1;
  constant CMD_HOST_PUSH         : integer := 2;
  constant CMD_CONNECT           : integer := 3;
  constant CMD_CLOSE             : integer := 4;
  constant CMD_WRITE_BYTE        : integer := 5;
  constant CMD_WRITE_FLUSH       : integer := 6;
  constant CMD_READ_BYTE         : integer := 7;
  constant CMD_RANDOM_BYTE       : integer := 8;
  constant CMD_GETENV_RESET      : integer := 9;
  constant CMD_GETENV_PUSH       : integer := 10;
  constant CMD_GETENV_LOOKUP     : integer := 11;
  constant CMD_GETENV_BYTE       : integer := 12;
  constant CMD_WAIT_READY        : integer := 13;
  constant CMD_WAIT_READY_STDIN  : integer := 14;
  constant CMD_STDIN_READ_BYTE   : integer := 15;
  constant CMD_STDOUT_WRITE_BYTE : integer := 16;
  constant CMD_STDOUT_FLUSH      : integer := 17;
  constant CMD_STDERR_WRITE_BYTE : integer := 18;
  constant CMD_EXIT              : integer := 19;
  constant CMD_LISTEN            : integer := 20;
  constant CMD_ACCEPT            : integer := 21;

  -- The two foreign functions. Both are impure: they read and mutate
  -- state on the C side (the connection table, the stdout buffer, the
  -- OS clock), so GHDL must not assume repeated calls are
  -- interchangeable with one call reused. Each is declared here with
  -- its real signature; the package body gives it the unreachable
  -- placeholder body GHDL's VHPIDIRECT convention expects, and the
  -- `foreign` attribute below redirects every call to native.c instead.
  impure function cx_dispatch(cmd, a0, a1 : integer) return integer;
  attribute foreign of cx_dispatch : function is "VHPIDIRECT cx_dispatch";

  impure function cx_now_ms return real;
  attribute foreign of cx_now_ms : function is "VHPIDIRECT cx_now_ms";

  -- One clock, shared by every process in every program this client
  -- builds. convex_transport.vhdl's clock_gen process is its only
  -- driver.
  signal clk : std_logic := '0';

  -- The request/acknowledge bus, split into two records so each has
  -- exactly one writer in any elaborated design: xport_req is driven
  -- only by the driver-side xport_call procedure below (called from
  -- whichever process is the current program's driver), and xport_ack
  -- is driven only by convex_transport's transport process directly.
  -- GHDL requires an unresolved signal's complete set of drivers to
  -- come from one process (or one procedure-call chain rooted in one
  -- process); splitting by writer, rather than sharing one record
  -- written by both sides, keeps every field within that rule instead
  -- of relying on cross-process per-element driver merging.
  type xport_req_t is record
    req : std_logic;
    cmd : integer;
    a0  : integer;
    a1  : integer;
  end record xport_req_t;

  type xport_ack_t is record
    ack      : std_logic;
    result   : integer;
    result_r : real;
  end record xport_ack_t;

  constant XPORT_REQ_INIT : xport_req_t := (req => '0', cmd => 0, a0 => 0, a1 => 0);
  constant XPORT_ACK_INIT : xport_ack_t := (ack => '0', result => 0, result_r => 0.0);

  signal xport_req : xport_req_t := XPORT_REQ_INIT;
  signal xport_ack : xport_ack_t := XPORT_ACK_INIT;

  -- Issues one bus transaction and blocks (via an event wait on
  -- xport_ack.ack, never a fixed-duration wait) until convex_transport's
  -- process has serviced it. Only legal to call from a process, or from
  -- a procedure called (directly or indirectly) from a process, because
  -- it contains a wait statement -- which is exactly the point: every
  -- crossing of this boundary is a real synchronized bus transaction
  -- against clk, not a plain function call that happens to run some C
  -- code. VHDL only allows a subprogram to signal-assign a signal that
  -- is one of its own formal parameters, so the request side (the only
  -- side this procedure writes) is threaded through explicitly; the
  -- acknowledge side is only ever read here, which needs no parameter.
  procedure xport_call(
    signal rq       : inout xport_req_t;
    cmd, a0, a1     : in integer;
    result          : out integer
  );

  -- The one operation with a real-valued result. Kept separate from
  -- xport_call's integer result because VHPIDIRECT fixes a foreign
  -- function's return type at declaration time.
  procedure xport_now_ms(signal rq : inout xport_req_t; result : out real);

end package convex_native;

package body convex_native is

  -- Never executed: GHDL's `foreign` attribute redirects every call to
  -- native.c before this body would run, exactly as this project's
  -- feasibility probe established.
  impure function cx_dispatch(cmd, a0, a1 : integer) return integer is
  begin
    assert false severity failure;
  end function cx_dispatch;

  impure function cx_now_ms return real is
  begin
    assert false severity failure;
  end function cx_now_ms;

  procedure xport_call(
    signal rq       : inout xport_req_t;
    cmd, a0, a1     : in integer;
    result          : out integer
  ) is
    variable posted : std_logic;
  begin
    rq.cmd <= cmd;
    rq.a0  <= a0;
    rq.a1  <= a1;
    posted := not rq.req;
    rq.req <= posted;
    wait until xport_ack.ack = posted;
    result := xport_ack.result;
  end procedure xport_call;

  procedure xport_now_ms(signal rq : inout xport_req_t; result : out real) is
    variable discard : integer;
  begin
    -- convex_transport's process samples cx_now_ms on every bus
    -- transaction, not only this one, so a CMD_NOP round trip is
    -- enough to pick up a fresh reading through the same clocked
    -- handshake instead of an unsynchronized read of a bare signal.
    xport_call(rq, CMD_NOP, 0, 0, discard);
    result := xport_ack.result_r;
  end procedure xport_now_ms;

end package body convex_native;
