library ieee;
use ieee.std_logic_1164.all;
use work.convex_native.all;

entity smoke is
end entity smoke;

architecture behav of smoke is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable r : integer;
    variable b : integer;
    variable t : real;
    variable req : string(1 to 37) := "GET / HTTP/1.1" & character'val(13) & character'val(10) &
                                       "Host: example.com" & character'val(13) & character'val(10) &
                                       character'val(13) & character'val(10);
    variable handle : integer;
    variable count : integer := 0;
  begin
    xport_call(xport_req, CMD_HOST_RESET, 0, 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('e'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('x'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('a'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('m'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('p'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('l'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('e'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('.'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('c'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('o'), 0, r);
    xport_call(xport_req, CMD_HOST_PUSH, character'pos('m'), 0, r);

    xport_call(xport_req, CMD_CONNECT, 443, 1, handle);
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
    report "PASS smoke";
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
