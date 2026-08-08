-- convex_http.vhdl - a small hand-written HTTP/1.1 client, just capable
-- enough for Convex's documented JSON /api/query, /api/mutation and
-- /api/action endpoints and the WebSocket upgrade handshake /api/sync
-- needs. Request framing, status-line and header parsing, and both
-- Content-Length and chunked response-body decoding are all written here,
-- driving the request/acknowledge circuit in convex_transport.vhdl one byte at a
-- time exactly as client/tests/transport_smoke.vhdl already proved works
-- end to end, including a real TLS handshake.
--
-- There is deliberately no generic header-list type: every request this
-- client ever sends has a fixed, small set of headers it already knows at
-- the call site, so building one directly into a byte buffer (matching
-- convex_buffer.vhdl and convex_json.vhdl's own style) needs no
-- allocation and no intermediate representation.
use work.convex_buffer.all;
use work.convex_json.all;
use work.convex_native.all;

package convex_http is

  constant HTTP_HOST_CAP : natural := 255;
  constant HTTP_PATH_CAP : natural := 255;

  type http_endpoint_t is record
    tls           : boolean;
    host          : byte_array(0 to HTTP_HOST_CAP - 1);
    host_len      : natural;
    port_num      : integer;
    -- The URL's own path with any trailing slash trimmed, so
    -- concatenating "/api/query" onto it never produces a doubled
    -- separator. Empty for an ordinary Convex deployment URL; only a
    -- self-hosted deployment mounted under a path prefix needs it.
    base_path     : byte_array(0 to HTTP_PATH_CAP - 1);
    base_path_len : natural;
  end record http_endpoint_t;

  -- Parses a Convex deployment URL into its connection parameters. Only
  -- http, https, ws and wss schemes are accepted (ws/wss are equivalent to
  -- http/https here: the Live sync endpoint is dialed with this same
  -- connection logic before being handed to the WebSocket upgrade).
  procedure http_parse_endpoint(url : in string; ep : inout http_endpoint_t; ok : out boolean);

  -- Connects a transport handle to ep, completing a TLS handshake when
  -- ep.tls is set. handle is a native.c connection-table index (see
  -- convex_native.vhdl's CMD_CONNECT), or negative on failure.
  procedure http_connect(
    signal rq : inout xport_req_t;
    ep        : in http_endpoint_t;
    handle    : out integer;
    ok        : out boolean
  );

  -- === request building: appends directly into a caller's byte buffer ===

  -- Writes "METHOD base_path+path HTTP/1.1\r\n".
  procedure http_write_request_line(
    buf    : inout byte_array;
    len    : inout natural;
    method : in string;
    ep     : in http_endpoint_t;
    path   : in string
  );

  procedure http_write_header(buf : inout byte_array; len : inout natural; name : in string; value : in string);
  procedure http_write_header_int(buf : inout byte_array; len : inout natural; name : in string; value : in integer);

  -- Ends the header block with the blank line that separates it from any
  -- response body.
  procedure http_end_headers(buf : inout byte_array; len : inout natural);

  -- Sends buf(0 to len-1) over handle. ok is false on any write or flush
  -- failure reported by the native transport.
  procedure http_send(
    signal rq  : inout xport_req_t;
    handle     : in integer;
    buf        : in byte_array;
    len        : in natural;
    ok         : out boolean
  );

  -- Reads one HTTP/1.1 response from handle: the status line, every
  -- header (captured verbatim into header_buf so http_header_value can
  -- look one up afterward), and the response body -- decoded whether it is
  -- with Content-Length or chunked Transfer-Encoding. ok is false for a
  -- malformed response, or a header block or response body that will not fit
  -- caller's buffers, or a transport read failure or timeout.
  procedure http_read_response(
    signal rq  : inout xport_req_t;
    handle     : in integer;
    timeout_ms : in integer;
    status     : out integer;
    header_buf : inout byte_array;
    header_len : out natural;
    resp_body  : inout byte_array;
    body_len   : out natural;
    ok         : out boolean
  );

  -- Case-insensitive lookup of one header's trimmed value within the raw
  -- header text http_read_response captured. Only the first matching
  -- header is returned.
  procedure http_header_value(
    header_buf : in byte_array;
    header_len : in natural;
    name       : in string;
    dst        : inout byte_array;
    dst_len    : inout natural;
    found      : out boolean
  );

end package convex_http;

package body convex_http is

  procedure http_parse_endpoint(url : in string; ep : inout http_endpoint_t; ok : out boolean) is
    variable scheme_end : integer := -1;
    variable tls : boolean;
    variable host_start : natural;
    variable p : natural;
    variable port_digits : byte_array(0 to 7);
    variable port_ndig : natural := 0;
    variable pv : integer;
    variable pok : boolean;
    variable path_start : integer := -1;
  begin
    ok := false;
    ep.tls := false;
    ep.host_len := 0;
    ep.port_num := 0;
    ep.base_path_len := 0;

    -- Find "://".
    for i in url'low to url'high - 2 loop
      if url(i) = ':' and url(i + 1) = '/' and url(i + 2) = '/' then
        scheme_end := i;
        exit;
      end if;
    end loop;
    if scheme_end < 0 then
      return;
    end if;
    if url(url'low to scheme_end - 1) = "https" or url(url'low to scheme_end - 1) = "wss" then
      tls := true;
    elsif url(url'low to scheme_end - 1) = "http" or url(url'low to scheme_end - 1) = "ws" then
      tls := false;
    else
      return;
    end if;
    ep.tls := tls;

    host_start := scheme_end + 3;
    if host_start > url'high then
      return; -- no host at all
    end if;

    -- host runs until ':' (port_num), '/' (path), or end of string.
    p := host_start;
    while p <= url'high and url(p) /= ':' and url(p) /= '/' loop
      if ep.host_len > HTTP_HOST_CAP - 1 then
        return;
      end if;
      ep.host(ep.host_len) := character'pos(url(p));
      ep.host_len := ep.host_len + 1;
      p := p + 1;
    end loop;
    if ep.host_len = 0 then
      return;
    end if;

    if p <= url'high and url(p) = ':' then
      p := p + 1;
      while p <= url'high and url(p) /= '/' loop
        if character'pos(url(p)) < character'pos('0') or character'pos(url(p)) > character'pos('9') then
          return;
        end if;
        if port_ndig > port_digits'high then
          return;
        end if;
        port_digits(port_ndig) := character'pos(url(p)) - character'pos('0');
        port_ndig := port_ndig + 1;
        p := p + 1;
      end loop;
      if port_ndig = 0 then
        return;
      end if;
      pv := 0;
      for i in 0 to port_ndig - 1 loop
        pv := pv * 10 + port_digits(i);
      end loop;
      if pv < 1 or pv > 65535 then
        return;
      end if;
      ep.port_num := pv;
    elsif tls then
      ep.port_num := 443;
    else
      ep.port_num := 80;
    end if;

    if p <= url'high and url(p) = '/' then
      path_start := p;
    end if;
    if path_start >= 0 then
      p := path_start;
      while p <= url'high loop
        if ep.base_path_len > HTTP_PATH_CAP - 1 then
          return;
        end if;
        ep.base_path(ep.base_path_len) := character'pos(url(p));
        ep.base_path_len := ep.base_path_len + 1;
        p := p + 1;
      end loop;
      -- Trim one trailing slash so concatenating "/api/query" onto it
      -- never doubles the separator.
      if ep.base_path_len > 0 and ep.base_path(ep.base_path_len - 1) = character'pos('/') then
        ep.base_path_len := ep.base_path_len - 1;
      end if;
    end if;

    ok := true;
  end procedure http_parse_endpoint;

  procedure http_connect(
    signal rq : inout xport_req_t;
    ep        : in http_endpoint_t;
    handle    : out integer;
    ok        : out boolean
  ) is
    variable r : integer;
    variable use_tls : integer;
  begin
    xport_call(rq, CMD_HOST_RESET, 0, 0, r);
    for i in 0 to ep.host_len - 1 loop
      xport_call(rq, CMD_HOST_PUSH, ep.host(i), 0, r);
    end loop;
    if ep.tls then
      use_tls := 1;
    else
      use_tls := 0;
    end if;
    xport_call(rq, CMD_CONNECT, ep.port_num, use_tls, handle);
    ok := handle >= 0;
  end procedure http_connect;

  procedure http_write_request_line(
    buf    : inout byte_array;
    len    : inout natural;
    method : in string;
    ep     : in http_endpoint_t;
    path   : in string
  ) is
  begin
    buf_put_str(buf, len, method);
    buf_put_byte(buf, len, character'pos(' '));
    buf_put_slice(buf, len, ep.base_path, 0, ep.base_path_len);
    buf_put_str(buf, len, path);
    buf_put_str(buf, len, " HTTP/1.1" & character'val(13) & character'val(10));
  end procedure http_write_request_line;

  procedure http_write_header(buf : inout byte_array; len : inout natural; name : in string; value : in string) is
  begin
    buf_put_str(buf, len, name);
    buf_put_str(buf, len, ": ");
    buf_put_str(buf, len, value);
    buf_put_byte(buf, len, 13);
    buf_put_byte(buf, len, 10);
  end procedure http_write_header;

  procedure http_write_header_int(buf : inout byte_array; len : inout natural; name : in string; value : in integer) is
  begin
    buf_put_str(buf, len, name);
    buf_put_str(buf, len, ": ");
    buf_put_int(buf, len, value);
    buf_put_byte(buf, len, 13);
    buf_put_byte(buf, len, 10);
  end procedure http_write_header_int;

  procedure http_end_headers(buf : inout byte_array; len : inout natural) is
  begin
    buf_put_byte(buf, len, 13);
    buf_put_byte(buf, len, 10);
  end procedure http_end_headers;

  procedure http_send(
    signal rq  : inout xport_req_t;
    handle     : in integer;
    buf        : in byte_array;
    len        : in natural;
    ok         : out boolean
  ) is
    variable r : integer;
  begin
    ok := false;
    for i in 0 to len - 1 loop
      xport_call(rq, CMD_WRITE_BYTE, handle, buf(buf'low + i), r);
      if r < 0 then
        return;
      end if;
    end loop;
    xport_call(rq, CMD_WRITE_FLUSH, handle, 0, r);
    ok := r >= 0;
  end procedure http_send;

  -- True when header_buf(off to off+4) begins the "\r\n\r\n" that ends a
  -- header block, i.e. the previous four bytes read were exactly that
  -- sequence.
  function ends_header_block(header_buf : byte_array; header_len : natural) return boolean is
  begin
    if header_len < 4 then
      return false;
    end if;
    return header_buf(header_len - 4) = 13 and header_buf(header_len - 3) = 10 and
           header_buf(header_len - 2) = 13 and header_buf(header_len - 1) = 10;
  end function ends_header_block;

  procedure http_header_value(
    header_buf : in byte_array;
    header_len : in natural;
    name       : in string;
    dst        : inout byte_array;
    dst_len    : inout natural;
    found      : out boolean
  ) is
    variable line_start, line_end, colon : integer;
    variable value_start, value_end : natural;
  begin
    found := false;
    -- Skip the status line: start scanning after its terminating CRLF.
    line_start := -1;
    for j in 0 to header_len - 2 loop
      if header_buf(j) = 13 and header_buf(j + 1) = 10 then
        line_start := j + 2;
        exit;
      end if;
    end loop;
    if line_start < 0 then
      return;
    end if;

    while line_start < header_len loop
      line_end := line_start;
      while line_end < header_len - 1 and not (header_buf(line_end) = 13 and header_buf(line_end + 1) = 10) loop
        line_end := line_end + 1;
      end loop;
      if line_end = line_start then
        return; -- a blank line: end of headers, no more to check
      end if;
      colon := -1;
      for j in line_start to line_end - 1 loop
        if header_buf(j) = character'pos(':') then
          colon := j;
          exit;
        end if;
      end loop;
      if colon >= 0 then
        if buf_eq_str_ci(header_buf, line_start, colon - line_start, name) then
          value_start := colon + 1;
          while value_start < line_end and header_buf(value_start) = character'pos(' ') loop
            value_start := value_start + 1;
          end loop;
          value_end := line_end;
          while value_end > value_start and header_buf(value_end - 1) = character'pos(' ') loop
            value_end := value_end - 1;
          end loop;
          buf_put_slice(dst, dst_len, header_buf, value_start, value_end - value_start);
          found := true;
          return;
        end if;
      end if;
      line_start := line_end + 2;
    end loop;
  end procedure http_header_value;

  procedure http_read_response(
    signal rq  : inout xport_req_t;
    handle     : in integer;
    timeout_ms : in integer;
    status     : out integer;
    header_buf : inout byte_array;
    header_len : out natural;
    resp_body  : inout byte_array;
    body_len   : out natural;
    ok         : out boolean
  ) is
    variable b, r : integer;
    variable hlen : natural := 0;
    variable line_end, sp1, sp2 : integer;
    variable code_start : natural;
    variable code_end : integer;
    variable status_val : integer;
    variable status_ok : boolean;
    variable clen_buf : byte_array(0 to 15);
    variable clen_len : natural;
    variable clen_found : boolean;
    variable content_length : integer;
    variable te_buf : byte_array(0 to 31);
    variable te_len : natural;
    variable te_found : boolean;
    variable chunked : boolean;
    variable blen : natural := 0;
    variable want : integer;
    variable chunk_digits : byte_array(0 to 7);
    variable chunk_ndig : natural;
    variable chunk_size : integer;
    variable hv : integer;
    variable cr1, lf1 : integer;
  begin
    status := 0;
    header_len := 0;
    body_len := 0;
    ok := false;

    -- Read byte by byte until the header block's terminating blank line.
    loop
      xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b);
      if b < 0 then
        return;
      end if;
      if hlen >= header_buf'length then
        return; -- headers too large for the caller's scratch buffer
      end if;
      buf_put_byte(header_buf, hlen, b);
      exit when ends_header_block(header_buf, hlen);
    end loop;
    header_len := hlen;

    -- Status line: "HTTP/1.1 200 OK\r\n".
    line_end := -1;
    for i in 0 to hlen - 2 loop
      if header_buf(i) = 13 and header_buf(i + 1) = 10 then
        line_end := i;
        exit;
      end if;
    end loop;
    if line_end < 0 then
      return;
    end if;
    sp1 := -1;
    sp2 := -1;
    for i in 0 to line_end - 1 loop
      if header_buf(i) = character'pos(' ') then
        if sp1 < 0 then
          sp1 := i;
        elsif sp2 < 0 then
          sp2 := i;
        end if;
      end if;
    end loop;
    if sp1 < 0 then
      return;
    end if;
    code_start := sp1 + 1;
    if sp2 >= 0 then
      code_end := sp2;
    else
      code_end := line_end;
    end if;
    if code_end <= code_start then
      return;
    end if;
    buf_parse_uint(header_buf, code_start, code_end - code_start, status_val, status_ok);
    if not status_ok then
      return;
    end if;
    status := status_val;

    clen_len := 0;
    http_header_value(header_buf, hlen, "content-length", clen_buf, clen_len, clen_found);
    te_len := 0;
    http_header_value(header_buf, hlen, "transfer-encoding", te_buf, te_len, te_found);
    chunked := false;
    if te_found then
      -- "chunked" is the only transfer-coding Convex's own API ever uses;
      -- a substring search would accept a coding this client cannot
      -- decode, so this checks for that exact value instead.
      chunked := buf_eq_str_ci(te_buf, 0, te_len, "chunked");
    end if;

    if chunked then
      loop
        -- Read one hex chunk-size line, terminated by CRLF (a chunk
        -- extension after ';' is not expected from Convex and is not
        -- supported).
        chunk_ndig := 0;
        loop
          xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b);
          if b < 0 then
            return;
          end if;
          if b = 13 then
            xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, lf1);
            if lf1 /= 10 then
              return;
            end if;
            exit;
          end if;
          hv := -1;
          if b >= character'pos('0') and b <= character'pos('9') then
            hv := b - character'pos('0');
          elsif b >= character'pos('a') and b <= character'pos('f') then
            hv := b - character'pos('a') + 10;
          elsif b >= character'pos('A') and b <= character'pos('F') then
            hv := b - character'pos('A') + 10;
          end if;
          if hv < 0 then
            return; -- a chunk extension or malformed size; not supported
          end if;
          if chunk_ndig > chunk_digits'high then
            return;
          end if;
          chunk_digits(chunk_ndig) := hv;
          chunk_ndig := chunk_ndig + 1;
        end loop;
        if chunk_ndig = 0 then
          return;
        end if;
        chunk_size := 0;
        for i in 0 to chunk_ndig - 1 loop
          chunk_size := chunk_size * 16 + chunk_digits(i);
        end loop;
        exit when chunk_size = 0;
        if blen + chunk_size > resp_body'length then
          return; -- would not fit the caller's resp_body buffer
        end if;
        for i in 1 to chunk_size loop
          xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b);
          if b < 0 then
            return;
          end if;
          buf_put_byte(resp_body, blen, b);
        end loop;
        -- trailing CRLF after each chunk's data
        xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, cr1);
        xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, lf1);
        if cr1 /= 13 or lf1 /= 10 then
          return;
        end if;
      end loop;
      -- Trailing CRLF after the terminating 0-size chunk; trailers are
      -- not expected from Convex's own API and are not supported.
      xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, cr1);
      xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, lf1);
      if cr1 /= 13 or lf1 /= 10 then
        return;
      end if;
    else
      want := 0;
      if clen_found then
        buf_parse_uint(clen_buf, 0, clen_len, want, status_ok);
        if not status_ok then
          return;
        end if;
      end if;
      if want > resp_body'length then
        return;
      end if;
      for i in 1 to want loop
        xport_call(rq, CMD_READ_BYTE, handle, timeout_ms, b);
        if b < 0 then
          return;
        end if;
        buf_put_byte(resp_body, blen, b);
      end loop;
    end if;

    body_len := blen;
    ok := true;
  end procedure http_read_response;

end package body convex_http;
