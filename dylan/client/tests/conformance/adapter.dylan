module: convex

// -------------------------------------------------------------------------
// NDJSON adapter protocol v1 -- test infrastructure, not public client
// code (see AGENTS.md). Speaks one JSON object per line, either over
// stdin/stdout or, when ADAPTER_LISTEN is set, over a single accepted TCP
// connection. Reserves stdout (or the accepted connection) for protocol
// events; every diagnostic goes to stderr.
//
// This process is a single-threaded reactor: the same loop that reads
// adapter commands also drives convex-sync.dylan's sync-pump, so no
// command is ever processed concurrently with a Live state change (see
// convex-sync.dylan's header comment for why that is enough of a
// single-owner guarantee without an actual thread).
// -------------------------------------------------------------------------

define constant $runtime-version = "Open Dylan 2026.2";
define constant $implementation = "native-dylan-c-ffi-libssl";

// -- line-oriented reading over a <connection> --

define class <line-reader> (<object>)
  slot lr-conn :: <connection>, required-init-keyword: conn:;
  slot lr-buf :: <byte-buffer> = make(<byte-buffer>);
end class <line-reader>;

// One bounded attempt to produce a complete line. Returns #f if nothing
// new arrived within poll-timeout-ms and no full line was already
// buffered; returns #"eof" if the peer closed with no further data.
define function try-read-line (reader :: <line-reader>, poll-timeout-ms :: <integer>) => (line :: <object>)
  let newline-at = find-byte(reader.lr-buf.bb-data, 10);
  if (newline-at)
    let line = bytes-to-string(reader.lr-buf.bb-data, start: 0, end: newline-at);
    bb-drop-front!(reader.lr-buf, newline-at + 1);
    strip-trailing-cr(line)
  else
    let revents = cx-poll-wait(reader.lr-conn.conn-fd, #t, #f, cx-now-ms() + poll-timeout-ms);
    if (revents <= 0)
      #f
    else
      let chunk = cx-read(reader.lr-conn, 8192, cx-now-ms() + poll-timeout-ms);
      if (~chunk)
        #"eof"
      else
        if (chunk.size > 0)
          bb-append!(reader.lr-buf, chunk);
        end if;
        let newline-at2 = find-byte(reader.lr-buf.bb-data, 10);
        if (newline-at2)
          let line = bytes-to-string(reader.lr-buf.bb-data, start: 0, end: newline-at2);
          bb-drop-front!(reader.lr-buf, newline-at2 + 1);
          strip-trailing-cr(line)
        else
          #f
        end if;
      end if;
    end if;
  end if
end function;

define function find-byte (data :: <byte-vector>, target :: <integer>) => (idx :: false-or(<integer>))
  block (done)
    for (i from 0 below data.size)
      if (data[i] = target) done(i) end if;
    end for;
    #f
  end block
end function;

define function strip-trailing-cr (s :: <byte-string>) => (out :: <byte-string>)
  if (s.size > 0 & s[s.size - 1] = '\r')
    copy-sequence(s, end: s.size - 1)
  else
    s
  end if
end function;

// -- emitting events --

define variable *out-conn* :: false-or(<connection>) = #f;

define function emit (obj :: <string-table>) => ()
  let text = concatenate(json-encode(obj), "\n");
  cx-write(*out-conn*, string-to-bytes(text), cx-now-ms() + 5000);
end function;

define function emit-ready (id :: <byte-string>) => ()
  let obj = make-json-object();
  json-object-set!(obj, "protocolVersion", 1);
  json-object-set!(obj, "id", id);
  json-object-set!(obj, "type", "ready");
  json-object-set!(obj, "language", "dylan");
  json-object-set!(obj, "implementation", $implementation);
  json-object-set!(obj, "runtime", $runtime-version);
  emit(obj);
end function;

define function error-object (e :: <convex-error>) => (obj :: <string-table>)
  let obj = make-json-object();
  json-object-set!(obj, "name", e.err-name);
  json-object-set!(obj, "message", e.err-message);
  if (e.err-data)
    json-object-set!(obj, "data", e.err-data);
  end if;
  obj
end function;

define function emit-error (id :: false-or(<byte-string>), e :: <convex-error>) => ()
  let obj = make-json-object();
  if (id)
    json-object-set!(obj, "id", id);
  end if;
  json-object-set!(obj, "type", "error");
  json-object-set!(obj, "error", error-object(e));
  if (e.err-logs)
    json-object-set!(obj, "logs", e.err-logs);
  end if;
  emit(obj);
end function;

define function emit-ack (id :: <byte-string>) => ()
  let obj = make-json-object();
  json-object-set!(obj, "id", id);
  json-object-set!(obj, "type", "ack");
  emit(obj);
end function;

define function emit-result (id :: <byte-string>, value :: <object>, logs :: false-or(<sequence>)) => ()
  let obj = make-json-object();
  json-object-set!(obj, "id", id);
  json-object-set!(obj, "type", "result");
  json-object-set!(obj, "value", value);
  if (logs)
    json-object-set!(obj, "logs", logs);
  end if;
  emit(obj);
end function;

define function emit-closed (id :: <byte-string>) => ()
  let obj = make-json-object();
  json-object-set!(obj, "id", id);
  json-object-set!(obj, "type", "closed");
  emit(obj);
end function;

define function emit-subscription-value
    (subscription-id :: <byte-string>, value :: <object>, logs :: false-or(<sequence>))
 => ()
  let obj = make-json-object();
  json-object-set!(obj, "type", "subscription");
  json-object-set!(obj, "subscriptionId", subscription-id);
  json-object-set!(obj, "value", value);
  if (logs)
    json-object-set!(obj, "logs", logs);
  end if;
  emit(obj);
end function;

define function emit-subscription-error (subscription-id :: <byte-string>, e :: <convex-error>) => ()
  let obj = make-json-object();
  json-object-set!(obj, "type", "subscription");
  json-object-set!(obj, "subscriptionId", subscription-id);
  json-object-set!(obj, "error", error-object(e));
  if (e.err-logs)
    json-object-set!(obj, "logs", e.err-logs);
  end if;
  emit(obj);
end function;

// -- adapter state --

define class <adapter-state> (<object>)
  slot as-base-url :: <parsed-url>, required-init-keyword: base-url:;
  slot as-mgr :: false-or(<sync-manager>) = #f;
  slot as-auth-token :: false-or(<byte-string>) = #f;
  // subscriptionId (string, harness-chosen) -> query-id (integer, internal)
  slot as-subscription-ids :: <string-table> = make(<string-table>);
  slot as-closed? :: <boolean> = #f;
end class <adapter-state>;

define function ensure-sync-manager (state :: <adapter-state>) => (mgr :: <sync-manager>)
  if (~state.as-mgr)
    state.as-mgr := sync-manager-new(state.as-base-url);
  end if;
  state.as-mgr
end function;

// -- command handling --

define function handle-hello (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  let version = json-object-ref(cmd, "protocolVersion");
  if (version ~= 1)
    emit-error(id, make-convex-error("ProtocolError", "unsupported adapter protocol version"));
  else
    emit-ready(id);
  end if;
end function;

define function handle-call (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  let operation = json-object-ref(cmd, "op");
  let path = json-object-ref(cmd, "path");
  let args = json-object-ref(cmd, "args");
  if (~instance?(path, <byte-string>) | ~instance?(args, <string-table>))
    emit-error(id, make-convex-error("ProtocolError", "malformed call command"));
  else
    let (value, err, logs) =
      convex-http-call(state.as-base-url, operation, path, args, state.as-auth-token, cx-now-ms() + 15000);
    if (err)
      emit-error(id, err);
    else
      emit-result(id, value, logs);
    end if;
  end if;
end function;

define function handle-set-auth (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  let token = json-object-ref(cmd, "token");
  if (~instance?(token, <byte-string>))
    emit-error(id, make-convex-error("ProtocolError", "malformed setAuth command"));
  else
    state.as-auth-token := if (token.size > 0) token else #f end if;
    if (state.as-mgr)
      sync-set-auth(state.as-mgr, token);
    end if;
    emit-ack(id);
  end if;
end function;

define function handle-subscribe (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  let subscription-id = json-object-ref(cmd, "subscriptionId");
  let path = json-object-ref(cmd, "path");
  let args = json-object-ref(cmd, "args");
  if (~instance?(subscription-id, <byte-string>) | ~instance?(path, <byte-string>)
        | ~instance?(args, <string-table>))
    emit-error(id, make-convex-error("ProtocolError", "malformed subscribe command"));
  else
    let mgr = ensure-sync-manager(state);
    // Replacing a live subscriptionId: tear the old one down completely
    // (synchronously, since this whole adapter is single-threaded) before
    // the new one is created, so no stale event can ever be relayed under
    // the new ack.
    let existing = element(state.as-subscription-ids, subscription-id, default: #f);
    if (existing)
      sync-unsubscribe(mgr, existing, cx-now-ms() + 5000);
    end if;
    let query-id = sync-subscribe(mgr, path, args, cx-now-ms() + 5000);
    element(state.as-subscription-ids, subscription-id) := query-id;
    emit-ack(id);
  end if;
end function;

define function handle-unsubscribe (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  let subscription-id = json-object-ref(cmd, "subscriptionId");
  if (~instance?(subscription-id, <byte-string>))
    emit-error(id, make-convex-error("ProtocolError", "malformed unsubscribe command"));
  else
    let existing = element(state.as-subscription-ids, subscription-id, default: #f);
    if (existing & state.as-mgr)
      sync-unsubscribe(state.as-mgr, existing, cx-now-ms() + 5000);
      remove-key!(state.as-subscription-ids, subscription-id);
    end if;
    emit-ack(id);
  end if;
end function;

define function handle-debug-disconnect (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  if (~state.as-mgr | ~sync-debug-disconnect(state.as-mgr))
    emit-error(id, make-convex-error("TransportError", "Live WebSocket is not connected"));
  else
    emit-ack(id);
  end if;
end function;

define function handle-close (state :: <adapter-state>, cmd :: <string-table>) => ()
  let id = json-object-ref(cmd, "id");
  state.as-closed? := #t;
  emit-closed(id);
end function;

define function dispatch-command (state :: <adapter-state>, line :: <byte-string>) => ()
  let (cmd, ok?) = json-parse(line);
  if (~ok? | ~instance?(cmd, <string-table>))
    emit-error(#f, make-convex-error("ProtocolError", "malformed adapter command"));
  else
    let operation = json-object-ref(cmd, "op");
    let id = json-object-ref(cmd, "id");
    select (operation by \=)
      "hello" => handle-hello(state, cmd);
      "query", "mutation", "action" => handle-call(state, cmd);
      "setAuth" => handle-set-auth(state, cmd);
      "subscribe" => handle-subscribe(state, cmd);
      "unsubscribe" => handle-unsubscribe(state, cmd);
      "debugDisconnect" => handle-debug-disconnect(state, cmd);
      "close" => handle-close(state, cmd);
      otherwise =>
        emit-error(if (instance?(id, <byte-string>)) id else #f end if,
                    make-convex-error("ProtocolError", "unknown adapter operation"));
    end select;
  end if;
end function;

// Relays every pending update across every active subscription, keyed by
// the harness's own subscriptionId strings rather than internal query
// ids.
define function drain-subscription-events (state :: <adapter-state>) => ()
  if (state.as-mgr)
    for (subscription-id in state.as-subscription-ids.key-sequence)
      let query-id = element(state.as-subscription-ids, subscription-id);
      block (next-subscription)
        while (#t)
          let update = sync-poll-update(state.as-mgr, query-id);
          if (~update)
            next-subscription();
          end if;
          if (update.upd-kind = #"value")
            emit-subscription-value(subscription-id, update.upd-value, update.upd-logs);
          else
            emit-subscription-error(subscription-id, update.upd-error);
          end if;
        end while;
      end block;
    end for;
  end if;
end function;

define function resolve-out-connection () => (conn :: <connection>, in-conn :: <connection>)
  let listen-spec = cx-getenv("ADAPTER_LISTEN");
  if (listen-spec)
    let colon = find-char(listen-spec, ':');
    let host = if (colon) copy-sequence(listen-spec, end: colon) else "0.0.0.0" end if;
    let target-port = string-to-integer(copy-sequence(listen-spec, start: (colon | -1) + 1));
    let conn = cx-listen-accept(host, target-port, cx-now-ms() + 30000);
    if (~conn)
      format-err("failed to accept ADAPTER_LISTEN connection\n");
      force-err();
      c-exit(1);
    end if;
    values(conn, conn)
  else
    values(cx-wrap-fd(1), cx-wrap-fd(0))
  end if
end function;

define function main () => ()
  let url-text = cx-getenv("CONVEX_URL");
  if (~url-text)
    format-err("CONVEX_URL is required\n");
    force-err();
    c-exit(1);
  end if;
  let base-url = parse-convex-url(url-text);
  if (~base-url)
    format-err("CONVEX_URL is not a valid http(s) URL\n");
    force-err();
    c-exit(1);
  end if;
  let (out-conn, in-conn) = resolve-out-connection();
  *out-conn* := out-conn;
  let state = make(<adapter-state>, base-url: base-url);
  let reader = make(<line-reader>, conn: in-conn);
  block (stop)
    while (~state.as-closed?)
      let line = try-read-line(reader, 20);
      if (instance?(line, <byte-string>))
        dispatch-command(state, line);
      elseif (line = #"eof")
        stop();
      end if;
      if (state.as-mgr)
        sync-pump(state.as-mgr, 20);
        drain-subscription-events(state);
      end if;
    end while;
  end block;
  if (out-conn ~== in-conn)
    cx-close(in-conn);
  end if;
  cx-close(out-conn);
end function;

main();
