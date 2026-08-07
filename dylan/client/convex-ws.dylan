module: convex

// -------------------------------------------------------------------------
// RFC 6455 WebSocket framing, hand-rolled over convex-native.dylan.
//
// Covers: the HTTP Upgrade handshake with a real Sec-WebSocket-Accept
// check (via libcrypto SHA-1, see convex-native.dylan), client-to-server
// masking, server-to-client frames (never masked, per spec, and rejected
// if they are), fragmented-message (continuation frame) reassembly,
// control frames (ping/pong/close) handled correctly in the middle of a
// fragmented message rather than only between messages, and UTF-8
// validation performed exactly once on the fully reassembled text
// message rather than per frame.
// -------------------------------------------------------------------------

define constant $ws-opcode-continuation = 0;
define constant $ws-opcode-text = 1;
define constant $ws-opcode-binary = 2;
define constant $ws-opcode-close = 8;
define constant $ws-opcode-ping = 9;
define constant $ws-opcode-pong = 10;

define constant $base64-alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

define function base64-encode (data :: <byte-vector>) => (out :: <byte-string>)
  let n = data.size;
  let groups = ceiling/(n, 3);
  let out = make(<byte-string>, size: groups * 4);
  for (g from 0 below groups)
    let i = g * 3;
    let b0 = data[i];
    let b1 = if (i + 1 < n) data[i + 1] else 0 end if;
    let b2 = if (i + 2 < n) data[i + 2] else 0 end if;
    let triple = ash(b0, 16) + ash(b1, 8) + b2;
    out[g * 4] := $base64-alphabet[logand(ash(triple, -18), 63)];
    out[g * 4 + 1] := $base64-alphabet[logand(ash(triple, -12), 63)];
    out[g * 4 + 2] :=
      if (i + 1 < n) $base64-alphabet[logand(ash(triple, -6), 63)] else '=' end if;
    out[g * 4 + 3] :=
      if (i + 2 < n) $base64-alphabet[logand(triple, 63)] else '=' end if;
  end for;
  out
end function;

// -- handshake --

define constant $ws-guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Sends the HTTP Upgrade request and validates the 101 response,
// including recomputing and checking Sec-WebSocket-Accept -- this client
// does not skip that check the way a from-scratch implementation without
// easy access to SHA-1 might have to.
define function ws-handshake
    (conn :: <connection>, host :: <byte-string>, path :: <byte-string>, deadline-ms :: <integer>)
 => (ok? :: <boolean>)
  let key-bytes = cx-random-bytes(16);
  let key-b64 = base64-encode(key-bytes);
  let request =
    concatenate("GET ", path, " HTTP/1.1\r\n",
                "Host: ", host, "\r\n",
                "Upgrade: websocket\r\n",
                "Connection: Upgrade\r\n",
                "Sec-WebSocket-Key: ", key-b64, "\r\n",
                "Sec-WebSocket-Version: 13\r\n",
                "Convex-Client: dylan-0.1.0\r\n",
                "\r\n");
  if (~cx-write(conn, string-to-bytes(request), deadline-ms))
    #f
  else
    let (status, header-text) = ws-read-handshake-headers(conn, deadline-ms);
    if (status ~= 101)
      #f
    else
      let accept = ws-header-value(header-text, "sec-websocket-accept");
      if (~accept)
        #f
      else
        let expected = base64-encode(cx-sha1(string-to-bytes(concatenate(key-b64, $ws-guid))));
        accept = expected
      end if;
    end if;
  end if
end function;

// The handshake response has no body, so this reads only up through the
// blank line that ends the header block, leaving anything past it (the
// start of the first WebSocket frame, if the server pipelined one) for
// the frame reader to pick up via the shared <ws-reader> buffer.
define function ws-read-handshake-headers
    (conn :: <connection>, deadline-ms :: <integer>)
 => (status :: false-or(<integer>), headers :: false-or(<byte-string>))
  let buf = make(<byte-buffer>);
  let header-end = #f;
  block (done)
    while (~header-end)
      if (cx-now-ms() > deadline-ms)
        done();
      end if;
      let chunk = cx-read(conn, 4096, deadline-ms);
      if (~chunk)
        done();
      end if;
      if (chunk.size > 0)
        bb-append!(buf, chunk);
      end if;
      header-end := find-blank-line(buf.bb-data, 0);
    end while;
  end block;
  if (~header-end)
    values(#f, #f)
  else
    let header-text = bytes-to-string(buf.bb-data, start: 0, end: header-end);
    bb-drop-front!(buf, header-end + 4);
    *ws-handshake-leftover* := buf.bb-data;
    let lines = split-lines(header-text);
    let status-line = lines[0];
    let first-space = find-char(status-line, ' ');
    let after = copy-sequence(status-line, start: first-space + 1);
    let second-space = find-char(after, ' ');
    let code-text = if (second-space) copy-sequence(after, end: second-space) else after end if;
    values(string-to-integer(code-text), header-text)
  end if
end function;

// Bytes read past the handshake's header block belong to the WebSocket
// stream proper; ws-open-reader below seeds the frame reader's buffer
// with them so nothing is dropped on the floor.
define variable *ws-handshake-leftover* :: <byte-vector> = make(<byte-vector>, size: 0);

define function ws-header-value (header-text :: <byte-string>, name :: <byte-string>) => (v :: false-or(<byte-string>))
  block (done)
    for (line in split-lines(header-text))
      let colon = find-char(line, ':');
      if (colon & to-lowercase(trim(copy-sequence(line, end: colon))) = name)
        done(trim(copy-sequence(line, start: colon + 1)));
      end if;
    end for;
    #f
  end block
end function;

// -- frame-level reader/writer --

define class <ws-reader> (<object>)
  slot wr-conn :: <connection>, required-init-keyword: conn:;
  slot wr-buf :: <byte-buffer>, required-init-keyword: buf:;
end class <ws-reader>;

define function ws-open-reader (conn :: <connection>) => (reader :: <ws-reader>)
  let buf = make(<byte-buffer>);
  bb-append!(buf, *ws-handshake-leftover*);
  *ws-handshake-leftover* := make(<byte-vector>, size: 0);
  make(<ws-reader>, conn: conn, buf: buf)
end function;

define function ws-fill-until
    (reader :: <ws-reader>, needed :: <integer>, deadline-ms :: <integer>)
 => (ok? :: <boolean>)
  block (done)
    while (reader.wr-buf.bb-data.size < needed)
      if (cx-now-ms() > deadline-ms)
        done(#f);
      end if;
      let chunk = cx-read(reader.wr-conn, max(needed - reader.wr-buf.bb-data.size, 4096), deadline-ms);
      if (~chunk)
        done(#f);
      end if;
      if (chunk.size > 0)
        bb-append!(reader.wr-buf, chunk);
      end if;
    end while;
    #t
  end block
end function;

// A raw frame: fin?, opcode, and unmasked payload bytes. Returns #f on
// any framing problem (short read, oversized length, or -- since a
// compliant server must never mask -- a masked server frame).
define function ws-read-frame
    (reader :: <ws-reader>, max-payload :: <integer>, deadline-ms :: <integer>)
 => (fin? :: false-or(<boolean>), opcode :: false-or(<integer>), payload :: false-or(<byte-vector>))
  if (~ws-fill-until(reader, 2, deadline-ms))
    values(#f, #f, #f)
  else
    let b0 = reader.wr-buf.bb-data[0];
    let b1 = reader.wr-buf.bb-data[1];
    let fin? = logand(b0, 128) ~= 0;
    let opcode = logand(b0, 15);
    let masked? = logand(b1, 128) ~= 0;
    let base-len = logand(b1, 127);
    if (masked?)
      values(#f, #f, #f) // a compliant server never masks; reject rather than misparse.
    else
      let (payload-len, header-len) =
        if (base-len < 126)
          values(base-len, 2)
        elseif (base-len = 126)
          if (~ws-fill-until(reader, 4, deadline-ms))
            values(-1, -1)
          else
            values(ash(reader.wr-buf.bb-data[2], 8) + reader.wr-buf.bb-data[3], 4)
          end if
        else
          if (~ws-fill-until(reader, 10, deadline-ms))
            values(-1, -1)
          else
            let v = 0;
            for (i from 2 below 10)
              v := ash(v, 8) + reader.wr-buf.bb-data[i];
            end for;
            values(v, 10)
          end if
        end if;
      if (payload-len < 0 | payload-len > max-payload)
        values(#f, #f, #f)
      elseif (~ws-fill-until(reader, header-len + payload-len, deadline-ms))
        values(#f, #f, #f)
      else
        let payload = copy-sequence(reader.wr-buf.bb-data, start: header-len, end: header-len + payload-len);
        bb-drop-front!(reader.wr-buf, header-len + payload-len);
        values(fin?, opcode, payload)
      end if;
    end if;
  end if
end function;

define function ws-write-frame
    (conn :: <connection>, opcode :: <integer>, payload :: <byte-vector>, deadline-ms :: <integer>)
 => (ok? :: <boolean>)
  let n = payload.size;
  let mask-key = cx-random-bytes(4);
  let header = make(<stretchy-vector>);
  add!(header, logior(128, opcode)); // FIN always set; this client never fragments outgoing frames.
  if (n < 126)
    add!(header, logior(128, n)); // MASK bit always set: every client frame must be masked.
  elseif (n < 65536)
    add!(header, logior(128, 126));
    add!(header, logand(ash(n, -8), 255));
    add!(header, logand(n, 255));
  else
    add!(header, logior(128, 127));
    for (shift in #(56, 48, 40, 32, 24, 16, 8, 0))
      add!(header, logand(ash(n, -shift), 255));
    end for;
  end if;
  for (b in mask-key)
    add!(header, b);
  end for;
  let masked-payload = make(<byte-vector>, size: n);
  for (i from 0 below n)
    masked-payload[i] := logxor(payload[i], mask-key[modulo(i, 4)]);
  end for;
  let frame = make(<byte-vector>, size: header.size + n);
  for (i from 0 below header.size)
    frame[i] := header[i];
  end for;
  for (i from 0 below n)
    frame[header.size + i] := masked-payload[i];
  end for;
  cx-write(conn, frame, deadline-ms)
end function;

define function ws-send-text
    (conn :: <connection>, text :: <byte-string>, deadline-ms :: <integer>) => (ok? :: <boolean>)
  ws-write-frame(conn, $ws-opcode-text, string-to-bytes(text), deadline-ms)
end function;

define function ws-send-close (conn :: <connection>, deadline-ms :: <integer>) => ()
  ws-write-frame(conn, $ws-opcode-close, make(<byte-vector>, size: 0), deadline-ms);
end function;

define function ws-send-pong (conn :: <connection>, payload :: <byte-vector>, deadline-ms :: <integer>) => ()
  ws-write-frame(conn, $ws-opcode-pong, payload, deadline-ms);
end function;

// -- UTF-8 validation, run once on a fully reassembled text message --

define function valid-utf8? (data :: <byte-vector>) => (well? :: <boolean>)
  let n = data.size;
  let i = 0;
  block (done)
    while (i < n)
      let b0 = data[i];
      let extra =
        if (b0 < 128) 0
        elseif (logand(b0, 224) = 192) 1
        elseif (logand(b0, 240) = 224) 2
        elseif (logand(b0, 248) = 240) 3
        else done(#f) end if;
      if (i + extra >= n)
        done(#f);
      end if;
      for (k from 1 to extra)
        if (logand(data[i + k], 192) ~= 128)
          done(#f);
        end if;
      end for;
      i := i + extra + 1;
    end while;
    #t
  end block
end function;

// -- message-level receive: assembles continuation frames, answers pings
// inline, and surfaces a close as its own result kind. Returns one of
// #"text" / #"binary" / #"close" / #"error" plus the assembled payload
// (a <byte-string> for text, a <byte-vector> for binary, #f otherwise).
define function ws-recv-message
    (reader :: <ws-reader>, deadline-ms :: <integer>)
 => (kind :: <symbol>, payload :: <object>)
  let message-opcode = #f;
  let assembled = make(<byte-buffer>);
  block (done)
    while (#t)
      let (fin?, opcode, frame-payload) = ws-read-frame(reader, 8 * 1024 * 1024, deadline-ms);
      if (~fin? & ~opcode)
        done(#"error", #f);
      end if;
      if (opcode = $ws-opcode-ping)
        ws-send-pong(reader.wr-conn, frame-payload, deadline-ms);
      elseif (opcode = $ws-opcode-pong)
        // No action needed: this client never depends on pong replies.
      elseif (opcode = $ws-opcode-close)
        done(#"close", frame-payload);
      else
        if (opcode ~= $ws-opcode-continuation)
          message-opcode := opcode;
        end if;
        bb-append!(assembled, frame-payload);
        if (fin?)
          if (message-opcode = $ws-opcode-text)
            if (valid-utf8?(assembled.bb-data))
              done(#"text", bytes-to-string(assembled.bb-data));
            else
              done(#"error", #f);
            end if;
          else
            done(#"binary", assembled.bb-data);
          end if;
        end if;
      end if;
    end while;
    values(#"error", #f)
  end block
end function;
