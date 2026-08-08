module: convex

// -------------------------------------------------------------------------
// HTTP/1.1 request/response framing, and the Convex HTTP query/mutation/
// action call on top of it.
//
// This is hand-rolled directly over convex-native.dylan's <connection>;
// nothing here delegates to a system HTTP library. It implements exactly
// the shape the pinned convex-rs sync profile expects: one connection per
// call, a JSON request body of {"path", "args", "format":"json"} POSTed
// to /api/{query,mutation,action}, and a {"status", ...} JSON envelope in
// response. See client/convex-sync.dylan for the WebSocket /api/sync side.
// -------------------------------------------------------------------------

define class <convex-error> (<object>)
  slot err-name :: <byte-string>, required-init-keyword: name:;
  slot err-message :: <byte-string>, required-init-keyword: message:;
  slot err-data :: <object> = #f, init-keyword: data:;
  slot err-logs :: false-or(<sequence>) = #f, init-keyword: logs:;
end class <convex-error>;

define function make-convex-error
    (name :: <byte-string>, message :: <byte-string>, #key data = #f, logs = #f)
 => (e :: <convex-error>)
  make(<convex-error>, name: name, message: message, data: data, logs: logs)
end function;

// -- URL parsing --
//
// Only what this client needs: scheme, host, port (defaulted per
// scheme), and path (defaulted to "/", trailing slash stripped so
// "{base}/api/query" never doubles a slash).
define class <parsed-url> (<object>)
  slot url-tls? :: <boolean>, required-init-keyword: tls?:;
  slot url-host :: <byte-string>, required-init-keyword: host:;
  slot url-port :: <integer>, required-init-keyword: port:;
  slot url-path :: <byte-string>, required-init-keyword: path:;
end class <parsed-url>;

define function parse-convex-url (url :: <byte-string>) => (parsed :: false-or(<parsed-url>))
  let tls? = #f;
  let rest = #f;
  if (url.size >= 8 & copy-sequence(url, end: 8) = "https://")
    tls? := #t;
    rest := copy-sequence(url, start: 8);
  elseif (url.size >= 7 & copy-sequence(url, end: 7) = "http://")
    tls? := #f;
    rest := copy-sequence(url, start: 7);
  else
    #f
  end if;
  if (~rest)
    #f
  else
    // Strip a trailing slash so path-building never doubles one.
    if (rest.size > 0 & rest[rest.size - 1] = '/')
      rest := copy-sequence(rest, end: rest.size - 1);
    end if;
    let slash = find-char(rest, '/');
    let host-part = if (slash) copy-sequence(rest, end: slash) else rest end if;
    let path-part = if (slash) copy-sequence(rest, start: slash) else "" end if;
    let colon = find-char(host-part, ':');
    let host = if (colon) copy-sequence(host-part, end: colon) else host-part end if;
    let port =
      if (colon)
        string-to-integer(copy-sequence(host-part, start: colon + 1))
      elseif (tls?)
        443
      else
        80
      end if;
    make(<parsed-url>, tls?: tls?, host: host, port: port, path: path-part)
  end if
end function;

define function find-char (s :: <byte-string>, ch :: <byte-character>) => (idx :: false-or(<integer>))
  block (done)
    for (i from 0 below s.size)
      if (s[i] = ch) done(i) end if;
    end for;
    #f
  end block
end function;

// -- byte-vector / byte-string conversion helpers, shared with the
// WebSocket and sync layers --

define function string-to-bytes (s :: <byte-string>) => (b :: <byte-vector>)
  let out = make(<byte-vector>, size: s.size);
  for (i from 0 below s.size)
    out[i] := as(<integer>, s[i]);
  end for;
  out
end function;

define function bytes-to-string (b :: <byte-vector>, #key start = 0, end: stop = #f) => (s :: <byte-string>)
  let real-stop = stop | b.size;
  let out = make(<byte-string>, size: real-stop - start);
  for (i from start below real-stop)
    out[i - start] := as(<byte-character>, b[i]);
  end for;
  out
end function;

// -- a small growable byte buffer used for accumulating a partial HTTP
// response (or a WebSocket message) across multiple reads --
define class <byte-buffer> (<object>)
  slot bb-data :: <byte-vector> = make(<byte-vector>, size: 0);
end class <byte-buffer>;

define function bb-append! (buf :: <byte-buffer>, more :: <byte-vector>) => ()
  let combined = make(<byte-vector>, size: buf.bb-data.size + more.size);
  for (i from 0 below buf.bb-data.size)
    combined[i] := buf.bb-data[i];
  end for;
  for (i from 0 below more.size)
    combined[buf.bb-data.size + i] := more[i];
  end for;
  buf.bb-data := combined;
end function;

define function bb-drop-front! (buf :: <byte-buffer>, count :: <integer>) => ()
  buf.bb-data := copy-sequence(buf.bb-data, start: count);
end function;

// Finds the byte offset of the first "\r\n\r\n" in buf starting at
// `from`, or #f. Used to detect the end of the HTTP header block.
define function find-blank-line (data :: <byte-vector>, from :: <integer>) => (idx :: false-or(<integer>))
  let target = #[13, 10, 13, 10];
  block (done)
    for (i from from to data.size - 4)
      if (data[i] = 13 & data[i + 1] = 10 & data[i + 2] = 13 & data[i + 3] = 10)
        done(i);
      end if;
    end for;
    #f
  end block
end function;

define function split-lines (text :: <byte-string>) => (lines :: <sequence>)
  let result = make(<stretchy-vector>);
  let start = 0;
  for (i from 0 below text.size)
    if (text[i] = '\r' | text[i] = '\n')
      if (i > start)
        add!(result, copy-sequence(text, start: start, end: i));
      end if;
      start := i + 1;
    end if;
  end for;
  if (start < text.size)
    add!(result, copy-sequence(text, start: start));
  end if;
  result
end function;

define function to-lowercase (s :: <byte-string>) => (out :: <byte-string>)
  let out = make(<byte-string>, size: s.size);
  for (i from 0 below s.size)
    let code = as(<integer>, s[i]);
    out[i] := if (code >= 65 & code <= 90) as(<byte-character>, code + 32) else s[i] end if;
  end for;
  out
end function;

define function trim (s :: <byte-string>) => (out :: <byte-string>)
  let start = 0;
  let stop = s.size;
  while (start < stop & (s[start] = ' ' | s[start] = '\t'))
    start := start + 1;
  end while;
  while (stop > start & (s[stop - 1] = ' ' | s[stop - 1] = '\t'))
    stop := stop - 1;
  end while;
  copy-sequence(s, start: start, end: stop)
end function;

// Reads one full HTTP/1.1 response: status line, headers, and body
// (Content-Length or chunked transfer-encoding; a response with neither
// is read until the connection closes). Returns (status-code, body-text)
// or (#f, #f) on a framing error or deadline.
define function http-read-response
    (conn :: <connection>, deadline-ms :: <integer>)
 => (status :: false-or(<integer>), body :: false-or(<byte-string>))
  let buf = make(<byte-buffer>);
  let header-end = #f;
  block (headers-done)
    while (~header-end)
      let chunk = cx-read(conn, 8192, deadline-ms);
      if (~chunk)
        headers-done();
      end if;
      if (chunk.size > 0)
        bb-append!(buf, chunk);
      end if;
      header-end := find-blank-line(buf.bb-data, max(0, buf.bb-data.size - chunk.size - 3));
      if (cx-now-ms() > deadline-ms & ~header-end)
        headers-done();
      end if;
    end while;
  end block;
  if (~header-end)
    values(#f, #f)
  else
    let header-text = bytes-to-string(buf.bb-data, start: 0, end: header-end);
    let lines = split-lines(header-text);
    if (lines.size = 0)
      values(#f, #f)
    else
      let status-line = lines[0];
      let first-space = find-char(status-line, ' ');
      if (~first-space)
        values(#f, #f)
      else
        let after = copy-sequence(status-line, start: first-space + 1);
        let second-space = find-char(after, ' ');
        let code-text = if (second-space) copy-sequence(after, end: second-space) else after end if;
        let status-code = string-to-integer(code-text);
        let content-length = #f;
        let chunked? = #f;
        for (i from 1 below lines.size)
          let line = lines[i];
          let colon = find-char(line, ':');
          if (colon)
            let name = to-lowercase(trim(copy-sequence(line, end: colon)));
            let hvalue = trim(copy-sequence(line, start: colon + 1));
            if (name = "content-length")
              content-length := string-to-integer(hvalue);
            elseif (name = "transfer-encoding" & to-lowercase(hvalue) = "chunked")
              chunked? := #t;
            end if;
          end if;
        end for;
        // Bytes already read past the header terminator belong to the body.
        bb-drop-front!(buf, header-end + 4);
        if (chunked?)
          let body = http-read-chunked-body(conn, buf, deadline-ms);
          values(status-code, body)
        elseif (content-length)
          let body = http-read-fixed-body(conn, buf, content-length, deadline-ms);
          values(status-code, body)
        else
          values(status-code, "")
        end if;
      end if;
    end if;
  end if
end function;

define function http-read-fixed-body
    (conn :: <connection>, buf :: <byte-buffer>, content-length :: <integer>, deadline-ms :: <integer>)
 => (body :: false-or(<byte-string>))
  block (done)
    while (buf.bb-data.size < content-length)
      if (cx-now-ms() > deadline-ms)
        done(#f);
      end if;
      let chunk = cx-read(conn, content-length - buf.bb-data.size, deadline-ms);
      if (~chunk)
        done(#f);
      end if;
      if (chunk.size > 0)
        bb-append!(buf, chunk);
      end if;
    end while;
    bytes-to-string(buf.bb-data, start: 0, end: content-length)
  end block
end function;

// Convex responses are small (2 MiB cap, per the reference clients), so
// chunked decoding is implemented directly against the accumulated
// buffer rather than streaming incrementally.
define function http-read-chunked-body
    (conn :: <connection>, buf :: <byte-buffer>, deadline-ms :: <integer>)
 => (body :: false-or(<byte-string>))
  let out = make(<stretchy-vector>);
  block (done)
    while (#t)
      // Ensure at least one CRLF-terminated line (the chunk size) is buffered.
      let size-end = #f;
      block (have-line)
        while (~size-end)
          for (i from 0 below max(0, buf.bb-data.size - 1))
            if (buf.bb-data[i] = 13 & buf.bb-data[i + 1] = 10)
              size-end := i;
              have-line();
            end if;
          end for;
          if (cx-now-ms() > deadline-ms)
            have-line();
          end if;
          let chunk = cx-read(conn, 8192, deadline-ms);
          if (~chunk)
            have-line();
          end if;
          if (chunk & chunk.size > 0)
            bb-append!(buf, chunk);
          end if;
        end while;
      end block;
      if (~size-end)
        done(#f);
      end if;
      let size-text = bytes-to-string(buf.bb-data, start: 0, end: size-end);
      // Ignore chunk extensions after ';', if any.
      let semi = find-char(size-text, ';');
      if (semi) size-text := copy-sequence(size-text, end: semi) end if;
      let chunk-size = hex-string-to-integer(trim(size-text));
      bb-drop-front!(buf, size-end + 2);
      if (chunk-size = 0)
        done(bytes-to-string(as(<byte-vector>, out)));
      end if;
      block (have-chunk)
        while (buf.bb-data.size < chunk-size + 2)
          if (cx-now-ms() > deadline-ms)
            done(#f);
          end if;
          let chunk = cx-read(conn, (chunk-size + 2) - buf.bb-data.size, deadline-ms);
          if (~chunk)
            done(#f);
          end if;
          if (chunk.size > 0)
            bb-append!(buf, chunk);
          end if;
        end while;
        have-chunk();
      end block;
      for (i from 0 below chunk-size)
        add!(out, buf.bb-data[i]);
      end for;
      bb-drop-front!(buf, chunk-size + 2); // + trailing CRLF
    end while;
    #f
  end block
end function;

define function hex-string-to-integer (s :: <byte-string>) => (v :: <integer>)
  let v = 0;
  for (ch in s)
    v := v * 16 + hex-digit-value(ch);
  end for;
  v
end function;

// Issues one Convex HTTP call (query, mutation, or action) and returns
// either (value, #f) on success or (#f, error). auth-token may be #f
// (no Authorization header sent) or a bearer token string.
define function convex-http-call
    (base :: <parsed-url>, operation :: <byte-string>, path :: <byte-string>,
     args :: <string-table>, auth-token :: false-or(<byte-string>), deadline-ms :: <integer>)
 => (value :: <object>, error :: false-or(<convex-error>), logs :: false-or(<sequence>))
  let body-obj = make-json-object();
  json-object-set!(body-obj, "path", path);
  json-object-set!(body-obj, "args", args);
  json-object-set!(body-obj, "format", "json");
  let body-text = json-encode(body-obj);

  let conn =
    if (base.url-tls?)
      cx-connect-tls(base.url-host, base.url-port, deadline-ms)
    else
      cx-connect-tcp(base.url-host, base.url-port, deadline-ms)
    end if;
  if (~conn)
    values(#f, make-convex-error("TransportError", "could not connect to Convex deployment"), #f)
  else
    let request-path = concatenate(base.url-path, "/api/", operation);
    let header-lines = make(<stretchy-vector>);
    add!(header-lines, concatenate("POST ", request-path, " HTTP/1.1\r\n"));
    add!(header-lines, concatenate("Host: ", base.url-host, "\r\n"));
    add!(header-lines, "Content-Type: application/json\r\n");
    add!(header-lines, "Accept: application/json\r\n");
    add!(header-lines, "Convex-Client: dylan-0.1.0\r\n");
    if (auth-token & auth-token.size > 0)
      add!(header-lines, concatenate("Authorization: Bearer ", auth-token, "\r\n"));
    end if;
    add!(header-lines, concatenate("Content-Length: ", integer-to-string(body-text.size), "\r\n"));
    add!(header-lines, "Connection: close\r\n");
    add!(header-lines, "\r\n");
    let request-text = apply(concatenate, "", as(<list>, header-lines));
    let full-request = concatenate(request-text, body-text);
    let sent? = cx-write(conn, string-to-bytes(full-request), deadline-ms);
    if (~sent?)
      cx-close(conn);
      values(#f, make-convex-error("TransportError", "failed writing HTTP request"), #f)
    else
      let (status, response-body) = http-read-response(conn, deadline-ms);
      cx-close(conn);
      if (~status | ~response-body)
        values(#f, make-convex-error("TransportError", "failed reading HTTP response"), #f)
      else
        let (envelope, ok?) = json-parse(response-body);
        if (~ok? | ~instance?(envelope, <string-table>))
          values(#f, make-convex-error("ProtocolError", "HTTP response was not valid Convex JSON"), #f)
        else
          let response-status = json-object-ref(envelope, "status");
          let raw-logs = json-object-ref(envelope, "logLines");
          let logs = if (instance?(raw-logs, <sequence>)) raw-logs else #f end if;
          if (response-status = "success")
            if (json-object-has-key?(envelope, "value"))
              values(json-object-ref(envelope, "value"), #f, logs)
            else
              values(#f, make-convex-error("ProtocolError", "HTTP response had an unknown status"), #f)
            end if;
          elseif (response-status = "error")
            let message = json-object-ref(envelope, "errorMessage", default: "Convex function failed");
            let data = json-object-ref(envelope, "errorData");
            values(#f, make-convex-error("FunctionError", message, data: data, logs: logs), #f)
          else
            values(#f, make-convex-error("ProtocolError", "HTTP response had an unknown status"), #f)
          end if;
        end if;
      end if;
    end if;
  end if
end function;
