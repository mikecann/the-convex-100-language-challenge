// convex_http.v - a small hand-written HTTP/1.1 client, just capable
// enough for Convex's documented JSON /api/query, /api/mutation and
// /api/action endpoints and the WebSocket upgrade handshake /api/sync
// needs. Request framing, status-line and header parsing, and both
// Content-Length and chunked response-body decoding are all written
// here, driving the request/acknowledge circuit in convex_transport.v
// one byte at a time exactly as client/tests/tcp_smoke.v and
// client/tests/tls_smoke.v already proved works end to end, including a
// real TLS handshake.
//
// This module owns everything one HTTP connection needs (the transport,
// the request buffer, the response header buffer, the response body
// buffer) as its own sub-instances, rather than accepting any of them as
// an argument - the same "smart buffer, not buffer-plus-package" shape
// convex_buffer.v uses, and for the identical reason: this toolchain
// cannot pass an array, a `ref` port, or a dynamic queue into a task or
// function. A caller reaches this module's buffers directly through its
// own hierarchical name (e.g. `client.http.req.put_byte(...)` from
// convex.v, one level up), never through an argument.
`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"
`include "client/convex_chars.vh"

module convex_http #(
  parameter REQ_CAP    = 16384,
  parameter HEADER_CAP = 8192,
  parameter BODY_CAP   = 1048576,
  parameter BODY_TOK   = 512
);

  convex_transport transport ();
  convex_buffer #(.MAXLEN(REQ_CAP))    req ();
  convex_buffer #(.MAXLEN(HEADER_CAP)) resp_headers ();
  convex_buffer #(.MAXLEN(BODY_CAP), .MAXTOK(BODY_TOK)) resp_body ();

  // === parsed endpoint state ==========================================
  bit    ep_tls;
  string ep_host;
  integer ep_port;
  // The URL's own path with any trailing slash trimmed, so concatenating
  // "/api/query" onto it never doubles the separator. Empty for an
  // ordinary Convex deployment URL; only a self-hosted deployment
  // mounted under a path prefix needs it.
  string ep_base_path;

  integer handle;

  // Parses a Convex deployment URL into ep_tls/ep_host/ep_port/
  // ep_base_path. Only http, https, ws and wss schemes are accepted
  // (ws/wss are equivalent to http/https here: the Live sync endpoint is
  // dialed with this same connection logic before being handed to the
  // WebSocket upgrade).
  task automatic parse_endpoint(input string url, output bit ok);
    integer scheme_end;
    integer i;
    integer host_start;
    integer p;
    string scheme;
    string port_str;
    integer pv;
    integer path_start;
    begin : main
      ok = 1'b0;
      ep_tls = 1'b0;
      ep_host = "";
      ep_port = 0;
      ep_base_path = "";
      scheme_end = -1;
      for (i = 0; i < url.len() - 2; i = i + 1) begin
        if (scheme_end < 0 && url[i] == ":" && url[i+1] == "/" && url[i+2] == "/") begin
          scheme_end = i;
        end
      end
      if (scheme_end < 0) disable main;
      scheme = url.substr(0, scheme_end - 1);
      if (scheme == "https" || scheme == "wss") ep_tls = 1'b1;
      else if (scheme == "http" || scheme == "ws") ep_tls = 1'b0;
      else disable main;

      host_start = scheme_end + 3;
      if (host_start > url.len() - 1) disable main; // no host at all

      p = host_start;
      while (p < url.len() && url[p] != ":" && url[p] != "/") begin
        ep_host = {ep_host, url[p]};
        p = p + 1;
      end
      if (ep_host.len() == 0) disable main;

      if (p < url.len() && url[p] == ":") begin
        p = p + 1;
        port_str = "";
        while (p < url.len() && url[p] != "/") begin
          if (url[p] < "0" || url[p] > "9") disable main;
          port_str = {port_str, url[p]};
          p = p + 1;
        end
        if (port_str.len() == 0) disable main;
        pv = 0;
        for (i = 0; i < port_str.len(); i = i + 1) begin
          pv = pv * 10 + (port_str[i] - "0");
        end
        if (pv < 1 || pv > 65535) disable main;
        ep_port = pv;
      end else if (ep_tls) begin
        ep_port = 443;
      end else begin
        ep_port = 80;
      end

      path_start = -1;
      if (p < url.len() && url[p] == "/") path_start = p;
      if (path_start >= 0) begin
        p = path_start;
        while (p < url.len()) begin
          ep_base_path = {ep_base_path, url[p]};
          p = p + 1;
        end
        if (ep_base_path.len() > 0 && ep_base_path[ep_base_path.len()-1] == "/") begin
          ep_base_path = ep_base_path.substr(0, ep_base_path.len() - 2);
        end
      end

      ok = 1'b1;
    end
  endtask

  // Connects `transport` to the parsed endpoint, completing a TLS
  // handshake when ep_tls is set. Sets `handle` to a native.c
  // connection-table index (see convex_opcodes.vh's CMD_CONNECT), or a
  // negative number on failure.
  task automatic connect(output bit ok);
    integer r, i, use_tls;
    begin
      transport.xport_call(`CMD_HOST_RESET, 0, 0, r);
      for (i = 0; i < ep_host.len(); i = i + 1) begin
        transport.xport_call(`CMD_HOST_PUSH, ep_host[i], 0, r);
      end
      use_tls = ep_tls ? 1 : 0;
      transport.xport_call(`CMD_CONNECT, ep_port, use_tls, handle);
      ok = (handle >= 0);
    end
  endtask

  task automatic close;
    integer r;
    begin
      if (handle >= 0) begin
        transport.xport_call(`CMD_CLOSE, handle, 0, r);
        handle = -1;
      end
    end
  endtask

  // === request building: appends directly into `req` =================

  task automatic write_request_line(input string method, input string path);
    begin
      req.put_str(method);
      req.put_byte(" ");
      req.put_str(ep_base_path);
      req.put_str(path);
      req.put_str(" HTTP/1.1");
      req.put_byte(`CR);
      req.put_byte(`LF);
    end
  endtask

  task automatic write_header(input string name, input string value);
    begin
      req.put_str(name);
      req.put_str(": ");
      req.put_str(value);
      req.put_byte(`CR);
      req.put_byte(`LF);
    end
  endtask

  task automatic write_header_int(input string name, input integer value);
    begin
      req.put_str(name);
      req.put_str(": ");
      req.put_int(value);
      req.put_byte(`CR);
      req.put_byte(`LF);
    end
  endtask

  // Ends the header block with the blank line that separates it from any
  // response body.
  task automatic end_headers;
    begin
      req.put_byte(`CR);
      req.put_byte(`LF);
    end
  endtask

  // Sends req's own bytes over `handle`. ok is false on any write or
  // flush failure reported by the native transport.
  task automatic send_request(output bit ok);
    integer i, r;
    begin : main
      ok = 1'b0;
      for (i = 0; i < req.length(); i = i + 1) begin
        transport.xport_call(`CMD_WRITE_BYTE, handle, req.get_byte(i), r);
        if (r < 0) disable main;
      end
      transport.xport_call(`CMD_WRITE_FLUSH, handle, 0, r);
      ok = (r >= 0);
    end
  endtask

  // === response reading ===============================================

  integer resp_status;

  function automatic bit is_digit_ch(input byte b);
    return (b >= "0" && b <= "9");
  endfunction

  // True when resp_headers' last 4 bytes are exactly CRLFCRLF, the
  // sequence that ends a header block.
  function automatic bit ends_header_block;
    integer hl;
    begin
      hl = resp_headers.length();
      if (hl < 4) return 1'b0;
      return (resp_headers.get_byte(hl-4) == `CR && resp_headers.get_byte(hl-3) == `LF &&
              resp_headers.get_byte(hl-2) == `CR && resp_headers.get_byte(hl-1) == `LF);
    end
  endfunction

  // Case-insensitive match of resp_headers[start..start+n) against name.
  function automatic bit header_name_matches(input integer start, input integer n, input string name);
    integer i;
    byte hc, nc;
    begin : main
      if (n != name.len()) return 1'b0;
      for (i = 0; i < n; i = i + 1) begin
        hc = resp_headers.get_byte(start + i);
        nc = name[i];
        if (hc >= "A" && hc <= "Z") hc = hc - "A" + "a";
        if (nc >= "A" && nc <= "Z") nc = nc - "A" + "a";
        if (hc != nc) return 1'b0;
      end
      return 1'b1;
    end
  endfunction

  // Looks up one header's trimmed value within resp_headers' raw text,
  // copying it (still as a `string`, since header values are always
  // short ASCII text this client compares or parses as a number) into
  // `value`. Only the first matching header is returned.
  task automatic header_value(input string name, output string value, output bit found);
    integer hl, line_start, line_end, colon, j;
    integer value_start, value_end;
    begin : main
      found = 1'b0;
      value = "";
      hl = resp_headers.length();
      line_start = -1;
      for (j = 0; j < hl - 1; j = j + 1) begin
        if (line_start < 0 && resp_headers.get_byte(j) == `CR && resp_headers.get_byte(j+1) == `LF) begin
          line_start = j + 2;
        end
      end
      if (line_start < 0) disable main;

      while (line_start < hl) begin
        line_end = line_start;
        while (line_end < hl - 1 &&
               !(resp_headers.get_byte(line_end) == `CR && resp_headers.get_byte(line_end+1) == `LF)) begin
          line_end = line_end + 1;
        end
        if (line_end == line_start) disable main; // blank line: end of headers
        colon = -1;
        for (j = line_start; j < line_end; j = j + 1) begin
          if (colon < 0 && resp_headers.get_byte(j) == ":") colon = j;
        end
        if (colon >= 0 && header_name_matches(line_start, colon - line_start, name)) begin
          value_start = colon + 1;
          while (value_start < line_end && resp_headers.get_byte(value_start) == " ") value_start = value_start + 1;
          value_end = line_end;
          while (value_end > value_start && resp_headers.get_byte(value_end-1) == " ") value_end = value_end - 1;
          value = "";
          for (j = value_start; j < value_end; j = j + 1) value = {value, resp_headers.get_byte(j)};
          found = 1'b1;
          disable main;
        end
        line_start = line_end + 2;
      end
    end
  endtask

  // Reads one HTTP/1.1 response from `handle`: the status line, every
  // header (captured verbatim into resp_headers so header_value can look
  // one up afterward), and the response body into resp_body - decoded
  // whether it is Content-Length or chunked Transfer-Encoding. ok is
  // false for a malformed response, a header block or body too large for
  // the fixed BODY_CAP/HEADER_CAP this instance was sized with, or a
  // transport read failure or timeout.
  task automatic read_response(input integer timeout_ms, output bit ok);
    integer b, r;
    integer line_end, sp1, sp2, i;
    integer code_start, code_end;
    string clen_str, te_str;
    bit clen_found, te_found, chunked;
    integer want;
    integer chunk_size;
    integer cr1, lf1;
    bit hex_ok;
    byte cmp_a, cmp_b;
    string chunked_kw;
    begin : main
      chunked_kw = "chunked";
      resp_status = 0;
      resp_headers.reset;
      resp_body.reset;
      ok = 1'b0;

      // Read byte by byte until the header block's terminating blank line.
      begin : header_loop
        forever begin
          transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, b);
          if (b < 0) disable main;
          resp_headers.put_byte(b[7:0]);
          if (resp_headers.overflow) disable main;
          if (ends_header_block()) disable header_loop;
        end
      end

      // Status line: "HTTP/1.1 200 OK\r\n".
      line_end = -1;
      for (i = 0; i < resp_headers.length() - 1; i = i + 1) begin
        if (line_end < 0 && resp_headers.get_byte(i) == `CR && resp_headers.get_byte(i+1) == `LF) begin
          line_end = i;
        end
      end
      if (line_end < 0) disable main;
      sp1 = -1;
      sp2 = -1;
      for (i = 0; i < line_end; i = i + 1) begin
        if (resp_headers.get_byte(i) == " ") begin
          if (sp1 < 0) sp1 = i;
          else if (sp2 < 0) sp2 = i;
        end
      end
      if (sp1 < 0) disable main;
      code_start = sp1 + 1;
      code_end = (sp2 >= 0) ? sp2 : line_end;
      if (code_end <= code_start) disable main;
      resp_status = 0;
      for (i = code_start; i < code_end; i = i + 1) begin
        if (!is_digit_ch(resp_headers.get_byte(i))) disable main;
        resp_status = resp_status * 10 + (resp_headers.get_byte(i) - "0");
      end

      header_value("content-length", clen_str, clen_found);
      header_value("transfer-encoding", te_str, te_found);
      chunked = 1'b0;
      if (te_found) begin
        // "chunked" is the only transfer-coding Convex's own API ever
        // uses; comparing the whole trimmed value (not a substring
        // search) refuses a coding this client cannot decode instead of
        // silently accepting it.
        chunked = (te_str.len() == 7);
        if (chunked) begin
          for (i = 0; i < 7; i = i + 1) begin
            cmp_a = te_str[i];
            cmp_b = chunked_kw[i];
            if (cmp_a >= "A" && cmp_a <= "Z") cmp_a = cmp_a - "A" + "a";
            if (cmp_a != cmp_b) chunked = 1'b0;
          end
        end
      end

      if (chunked) begin
        begin : chunk_loop
          forever begin
            chunk_size = 0;
            hex_ok = 1'b0;
            begin : size_loop
              forever begin
                transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, b);
                if (b < 0) disable main;
                if (b == `CR) begin
                  transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, lf1);
                  if (lf1 != `LF) disable main;
                  disable size_loop;
                end
                if (b >= "0" && b <= "9") begin
                  chunk_size = chunk_size * 16 + (b - "0");
                  hex_ok = 1'b1;
                end else if (b >= "a" && b <= "f") begin
                  chunk_size = chunk_size * 16 + (b - "a" + 10);
                  hex_ok = 1'b1;
                end else if (b >= "A" && b <= "F") begin
                  chunk_size = chunk_size * 16 + (b - "A" + 10);
                  hex_ok = 1'b1;
                end else begin
                  disable main; // a chunk extension or malformed size; not supported
                end
              end
            end
            if (!hex_ok) disable main;
            if (chunk_size == 0) disable chunk_loop;
            for (i = 0; i < chunk_size; i = i + 1) begin
              transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, b);
              if (b < 0) disable main;
              resp_body.put_byte(b[7:0]);
              if (resp_body.overflow) disable main;
            end
            transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, cr1);
            transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, lf1);
            if (cr1 != `CR || lf1 != `LF) disable main;
          end
        end
        // Trailing CRLF after the terminating 0-size chunk; trailers are
        // not expected from Convex's own API and are not supported.
        transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, cr1);
        transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, lf1);
        if (cr1 != `CR || lf1 != `LF) disable main;
      end else begin
        want = 0;
        if (clen_found) begin
          for (i = 0; i < clen_str.len(); i = i + 1) begin
            if (!is_digit_ch(clen_str[i])) disable main;
            want = want * 10 + (clen_str[i] - "0");
          end
        end
        for (i = 0; i < want; i = i + 1) begin
          transport.xport_call(`CMD_READ_BYTE, handle, timeout_ms, b);
          if (b < 0) disable main;
          resp_body.put_byte(b[7:0]);
          if (resp_body.overflow) disable main;
        end
      end

      ok = 1'b1;
    end
  endtask

  function automatic integer status;
    return resp_status;
  endfunction

endmodule
