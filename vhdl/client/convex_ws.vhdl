-- convex_ws.vhdl - a hand-written RFC 6455 WebSocket layer: the HTTP
-- Upgrade handshake, masked frame encode, unmasked frame decode with
-- fragmentation reassembly, and transparent Ping/Pong handling. Reuses
-- convex_http.vhdl's request-line and header-writing helpers for the
-- handshake request, and convex_native.vhdl's request/acknowledge circuit
-- for every byte actually sent or received, exactly like convex_http.vhdl
-- itself.
--
-- RFC 6455's masking cipher is the one place this client needs a genuine
-- bitwise XOR rather than the div/mod arithmetic convex_buffer.vhdl and
-- convex_json.vhdl otherwise get by with: every other field this file
-- reads or writes (FIN, opcode, the mask bit, the 7/16/64-bit payload
-- length) occupies a byte or a run of bytes on its own, so plain addition
-- and div/mod extract or combine them exactly like a bitwise OR or shift
-- would. IEEE numeric_std's `unsigned` type is the natural VHDL way to
-- get a real per-bit XOR: this is the one file in this client that opens
-- it, for that one operation.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.convex_buffer.all;
use work.convex_http.all;
use work.convex_native.all;

package convex_ws is

  type ws_opcode_t is (WS_CONTINUATION, WS_TEXT, WS_BINARY, WS_CLOSE, WS_PING, WS_PONG, WS_UNKNOWN);

  -- Sends the HTTP/1.1 Upgrade request (a random Sec-WebSocket-Key, as
  -- RFC 6455 5.2.2 requires) over an already-connected handle and reads
  -- the response. ok is false unless the response is a 101 status;
  -- LIMITATION (see README): the Sec-WebSocket-Accept value is not
  -- verified against the key this client sent, narrowing the trust check
  -- to "the deployment agreed to upgrade" rather than also proving it
  -- read this exact key back, matching this project's other clients that
  -- documented the same narrowing when SHA-1 was judged out of scope.
  procedure ws_handshake(
    signal rq  : inout xport_req_t;
    handle     : in integer;
    ep         : in http_endpoint_t;
    path       : in string;
    timeout_ms : in integer;
    ok         : out boolean
  );

  -- Writes one complete, masked frame. Convex's own sync messages are
  -- small enough that this client never fragments an outgoing message.
  procedure ws_write_frame(
    signal rq   : inout xport_req_t;
    handle      : in integer;
    opcode      : in ws_opcode_t;
    payload     : in byte_array;
    payload_len : in natural;
    ok          : out boolean
  );

  -- Reads one logical message, transparently reassembling continuation
  -- frames and transparently answering an interleaved Ping with a Pong.
  -- A Close frame is returned to the caller as-is, its payload (if any)
  -- copied into payload just like any other message, so the caller can
  -- log the peer's stated reason. ok is false for a malformed frame, a
  -- masked frame from the server (a protocol violation this client
  -- refuses rather than silently unmasking), a message too large for the
  -- caller's buffer, or a transport read failure or timeout.
  procedure ws_read_message(
    signal rq   : inout xport_req_t;
    handle      : in integer;
    timeout_ms  : in integer;
    opcode      : out ws_opcode_t;
    payload     : inout byte_array;
    payload_len : out natural;
    ok          : out boolean
  );

end package convex_ws;

package body convex_ws is

  -- Forward declaration: ws_read_message reads one raw frame at a time
  -- and reassembles/replies from within the same loop, so the raw-frame
  -- reader is broken out as its own procedure but is only ever called
  -- from ws_read_message.
  procedure read_one_frame(
    signal rq   : inout xport_req_t;
    handle      : in integer;
    timeout_ms  : in integer;
    fin         : out boolean;
    opcode      : out ws_opcode_t;
    payload     : inout byte_array;
    payload_len : out natural;
    ok          : out boolean
  );

  procedure ws_handshake(
    signal rq  : inout xport_req_t;
    handle     : in integer;
    ep         : in http_endpoint_t;
    path       : in string;
    timeout_ms : in integer;
    ok         : out boolean
  ) is
    variable key_raw : byte_array(0 to 15);
    variable key_b64 : byte_array(0 to 63);
    variable key_b64_len : natural := 0;
    variable rnd : integer;
    variable buf : byte_array(0 to 511);
    variable len : natural := 0;
    variable send_ok : boolean;
    variable status : integer;
    variable header_buf : byte_array(0 to 4095);
    variable header_len : natural;
    variable resp_body : byte_array(0 to 15);
    variable body_len : natural;
    variable read_ok : boolean;
  begin
    ok := false;
    for i in 0 to 15 loop
      xport_call(rq, CMD_RANDOM_BYTE, 0, 0, rnd);
      if rnd < 0 then
        return;
      end if;
      key_raw(i) := rnd;
    end loop;
    buf_put_base64(key_b64, key_b64_len, key_raw, 0, 16);

    http_write_request_line(buf, len, "GET", ep, path);
    -- ep's host is a byte slice, not a VHDL string, so the Host header
    -- is composed by hand rather than through http_write_header.
    buf_put_str(buf, len, "Host: ");
    buf_put_slice(buf, len, ep.host, 0, ep.host_len);
    buf_put_byte(buf, len, 13);
    buf_put_byte(buf, len, 10);
    http_write_header(buf, len, "Upgrade", "websocket");
    http_write_header(buf, len, "Connection", "Upgrade");
    -- http_write_header expects a `string`, not a byte slice, so the
    -- base64 key is written as a header by hand too.
    buf_put_str(buf, len, "Sec-WebSocket-Key: ");
    buf_put_slice(buf, len, key_b64, 0, key_b64_len);
    buf_put_byte(buf, len, 13);
    buf_put_byte(buf, len, 10);
    http_write_header(buf, len, "Sec-WebSocket-Version", "13");
    http_end_headers(buf, len);

    http_send(rq, handle, buf, len, send_ok);
    if not send_ok then
      return;
    end if;
    http_read_response(rq, handle, timeout_ms, status, header_buf, header_len, resp_body, body_len, read_ok);
    if not read_ok then
      return;
    end if;
    ok := status = 101;
  end procedure ws_handshake;

  procedure ws_write_frame(
    signal rq   : inout xport_req_t;
    handle      : in integer;
    opcode      : in ws_opcode_t;
    payload     : in byte_array;
    payload_len : in natural;
    ok          : out boolean
  ) is
    variable buf : byte_array(0 to 15);
    variable len : natural := 0;
    variable opcode_num : integer;
    variable mask : byte_array(0 to 3);
    variable rnd, r : integer;
    variable masked_buf : byte_array(0 to 4095);
    variable masked_len : natural := 0;
    variable send_ok : boolean;
  begin
    ok := false;
    case opcode is
      when WS_CONTINUATION => opcode_num := 0;
      when WS_TEXT => opcode_num := 1;
      when WS_BINARY => opcode_num := 2;
      when WS_CLOSE => opcode_num := 8;
      when WS_PING => opcode_num := 9;
      when WS_PONG => opcode_num := 10;
      when others => return;
    end case;

    buf_put_byte(buf, len, 128 + opcode_num); -- FIN=1, no extensions
    if payload_len <= 125 then
      buf_put_byte(buf, len, 128 + payload_len);
    elsif payload_len <= 65535 then
      buf_put_byte(buf, len, 128 + 126);
      buf_put_byte(buf, len, payload_len / 256);
      buf_put_byte(buf, len, payload_len mod 256);
    else
      -- Convex's own sync messages never approach this size; a payload
      -- this large is refused rather than framed with a 64-bit length
      -- this client's `integer`-bounded byte_array could not hold anyway.
      return;
    end if;

    for i in 0 to 3 loop
      xport_call(rq, CMD_RANDOM_BYTE, 0, 0, rnd);
      if rnd < 0 then
        return;
      end if;
      mask(i) := rnd;
      buf_put_byte(buf, len, rnd);
    end loop;

    send_ok := false;
    http_send(rq, handle, buf, len, send_ok);
    if not send_ok then
      return;
    end if;

    if payload_len > 0 then
      if payload_len > masked_buf'length then
        return; -- would not fit this procedure's own staging buffer
      end if;
      for i in 0 to payload_len - 1 loop
        buf_put_byte(
          masked_buf, masked_len,
          to_integer(to_unsigned(payload(payload'low + i), 8) xor to_unsigned(mask(i mod 4), 8))
        );
      end loop;
      http_send(rq, handle, masked_buf, masked_len, send_ok);
      if not send_ok then
        return;
      end if;
    end if;

    ok := true;
  end procedure ws_write_frame;

  procedure read_one_frame(
    signal rq   : inout xport_req_t;
    handle      : in integer;
    timeout_ms  : in integer;
    fin         : out boolean;
    opcode      : out ws_opcode_t;
    payload     : inout byte_array;
    payload_len : out natural;
    ok          : out boolean
  ) is
    variable b0, b1, b, e0, e1 : integer;
    variable masked : boolean;
    variable plen : integer;
    variable opcode_num : integer;
    variable plen_bytes : byte_array(0 to 7);
    variable pl : natural := 0;
  begin
    fin := false;
    opcode := WS_UNKNOWN;
    payload_len := 0;
    ok := false;

    xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b0);
    if b0 < 0 then
      return;
    end if;
    xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b1);
    if b1 < 0 then
      return;
    end if;

    fin := b0 >= 128;
    opcode_num := b0 mod 16;
    masked := b1 >= 128;
    if masked then
      return; -- a masked server frame is a protocol violation
    end if;
    plen := b1 mod 128;

    if plen = 126 then
      xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, e0);
      xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, e1);
      if e0 < 0 or e1 < 0 then
        return;
      end if;
      plen := e0 * 256 + e1;
    elsif plen = 127 then
      for i in 0 to 7 loop
        xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b);
        if b < 0 then
          return;
        end if;
        plen_bytes(i) := b;
      end loop;
      -- The four high-order bytes of a genuine Convex frame are always
      -- zero; refuse anything claiming a length this client's 32-bit
      -- integer could not represent instead of silently wrapping.
      if plen_bytes(0) /= 0 or plen_bytes(1) /= 0 or plen_bytes(2) /= 0 or plen_bytes(3) /= 0 then
        return;
      end if;
      plen := plen_bytes(4) * 16777216 + plen_bytes(5) * 65536 + plen_bytes(6) * 256 + plen_bytes(7);
    end if;

    if plen > payload'length then
      return; -- would not fit the caller's reassembly buffer
    end if;
    for i in 1 to plen loop
      xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b);
      if b < 0 then
        return;
      end if;
      buf_put_byte(payload, pl, b);
    end loop;
    payload_len := pl;

    case opcode_num is
      when 0 => opcode := WS_CONTINUATION;
      when 1 => opcode := WS_TEXT;
      when 2 => opcode := WS_BINARY;
      when 8 => opcode := WS_CLOSE;
      when 9 => opcode := WS_PING;
      when 10 => opcode := WS_PONG;
      when others => return;
    end case;
    ok := true;
  end procedure read_one_frame;

  procedure ws_read_message(
    signal rq   : inout xport_req_t;
    handle      : in integer;
    timeout_ms  : in integer;
    opcode      : out ws_opcode_t;
    payload     : inout byte_array;
    payload_len : out natural;
    ok          : out boolean
  ) is
    variable frame_fin : boolean;
    variable frame_opcode : ws_opcode_t;
    variable frame_payload : byte_array(0 to 4095);
    variable frame_len : natural;
    variable frame_ok : boolean;
    variable assembling : boolean := false;
    variable final_opcode : ws_opcode_t := WS_TEXT;
    variable assembled_len : natural := 0;
    variable pong_ok : boolean;
  begin
    opcode := WS_UNKNOWN;
    payload_len := 0;
    ok := false;

    loop
      read_one_frame(rq, handle, timeout_ms, frame_fin, frame_opcode, frame_payload, frame_len, frame_ok);
      if not frame_ok then
        return;
      end if;

      if frame_opcode = WS_PING then
        ws_write_frame(rq, handle, WS_PONG, frame_payload, frame_len, pong_ok);
        if not pong_ok then
          return;
        end if;
        next;
      elsif frame_opcode = WS_PONG then
        next;
      elsif frame_opcode = WS_CLOSE then
        if frame_len > payload'length then
          return;
        end if;
        buf_put_slice(payload, assembled_len, frame_payload, 0, frame_len);
        opcode := WS_CLOSE;
        payload_len := assembled_len;
        ok := true;
        return;
      end if;

      if not assembling then
        if frame_opcode = WS_CONTINUATION then
          final_opcode := WS_TEXT;
        else
          final_opcode := frame_opcode;
        end if;
        assembling := true;
      end if;

      if assembled_len + frame_len > payload'length then
        return; -- would not fit the caller's reassembly buffer
      end if;
      buf_put_slice(payload, assembled_len, frame_payload, 0, frame_len);

      if frame_fin then
        opcode := final_opcode;
        payload_len := assembled_len;
        ok := true;
        return;
      end if;
    end loop;
  end procedure ws_read_message;

end package body convex_ws;
