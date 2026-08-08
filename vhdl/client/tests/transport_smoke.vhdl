-- transport_smoke.vhdl - proves the whole foundation from inside one
-- elaborated design: the split req/ack bus in convex_native.vhdl
-- satisfies GHDL's single-driver-per-unresolved-signal rule (see
-- convex_native.vhdl's header comment), the transport process in
-- convex_transport.vhdl really calls native.c through VHPIDIRECT, and
-- the resulting connection performs a genuine TLS 1.2+/1.3 handshake
-- with certificate and hostname verification. It is hermetic: it
-- connects to `localhost` on a port the Dockerfile starts a local
-- `openssl s_server` on, rather than reaching out to the live internet
-- from inside a Docker build stage.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_native.all;

entity transport_smoke is
end entity transport_smoke;

architecture behav of transport_smoke is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable r : integer;
    variable b : integer;
    variable t : real;
    variable req : string(1 to 18) := "GET / HTTP/1.0" & character'val(13) & character'val(10) &
                                       character'val(13) & character'val(10);
    variable host : string(1 to 9) := "localhost";
    variable handle : integer;
    variable count : integer := 0;
  begin
    xport_call(xport_req, CMD_HOST_RESET, 0, 0, r);
    for i in host'range loop
      xport_call(xport_req, CMD_HOST_PUSH, character'pos(host(i)), 0, r);
    end loop;

    xport_call(xport_req, CMD_CONNECT, 44300, 1, handle);
    report "connect handle=" & integer'image(handle);
    assert handle >= 0 severity failure;

    for i in req'range loop
      xport_call(xport_req, CMD_WRITE_BYTE, handle, character'pos(req(i)), r);
    end loop;
    xport_call(xport_req, CMD_WRITE_FLUSH, handle, 0, r);
    report "flushed=" & integer'image(r);
    assert r > 0 severity failure;

    for i in 1 to 20 loop
      xport_call(xport_req, CMD_READ_BYTE, handle, 5000, b);
      exit when b < 0;
      count := count + 1;
      xport_call(xport_req, CMD_STDOUT_WRITE_BYTE, b, 0, r);
    end loop;
    xport_call(xport_req, CMD_STDOUT_FLUSH, 0, 0, r);
    report "read " & integer'image(count) & " bytes";
    assert count > 0 severity failure;

    xport_now_ms(xport_req, t);
    report "now_ms=" & real'image(t);

    xport_call(xport_req, CMD_CLOSE, handle, 0, r);
    report "PASS transport_smoke";
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
