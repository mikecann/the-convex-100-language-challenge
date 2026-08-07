module: convex

// -------------------------------------------------------------------------
// The Convex Live sync protocol over /api/sync, driven as a single-owner
// reactor: exactly one call path (sync-pump, invoked from the adapter's
// main loop) ever touches the WebSocket, mutates the query-set version,
// or decides to reconnect. Dylan's C-FFI boundary in this client has no
// thread primitives wired up, so rather than emulate the reference C
// client's dedicated worker thread, this client gets the same
// single-writer guarantee the simpler way: there is only one thread.
// Live progress happens only while the adapter is inside sync-pump,
// exactly as documented for the ALGOL60 client in this project.
//
// Session id is generated once, in sync-manager-new, and resent on every
// reconnect -- the two reference implementations in this repository
// disagree on this point (the C client mints a fresh one per reconnect);
// a stable per-lifetime session id is what a field literally named
// "session" suggests, and it is the choice made here.
// -------------------------------------------------------------------------

define constant $live-initial-backoff-ms = 100;
define constant $live-backoff-cap-ms = 15000;
define constant $live-backoff-doubling-limit-ms = 7500;
define constant $live-debug-reconnect-delay-ms = 100;
define constant $live-max-message-bytes = 2 * 1024 * 1024;
define constant $live-max-queue-depth = 64;

define constant $ts-zero = "AAAAAAAAAAA=";

define function base64-decode (s :: <byte-string>) => (out :: false-or(<byte-vector>))
  block (fail)
    let clean-len = s.size;
    while (clean-len > 0 & s[clean-len - 1] = '=')
      clean-len := clean-len - 1;
    end while;
    let out = make(<stretchy-vector>);
    let acc = 0;
    let bits = 0;
    for (i from 0 below clean-len)
      let idx = find-char($base64-alphabet, s[i]) | fail(#f);
      acc := logior(ash(acc, 6), idx);
      bits := bits + 6;
      if (bits >= 8)
        bits := bits - 8;
        add!(out, logand(ash(acc, -bits), 255));
        // Keep acc limited to just the still-unconsumed low bits so it
        // never grows past a machine word across a long input, rather
        // than accumulating the whole decoded stream's bits in one place.
        acc := logand(acc, ash(1, bits) - 1);
      end if;
    end for;
    as(<byte-vector>, out)
  end block
end function;

define function ts-to-base64 (value :: <integer>) => (s :: <byte-string>)
  let bytes = make(<byte-vector>, size: 8);
  let v = value;
  for (i from 0 below 8)
    bytes[i] := logand(v, 255);
    v := ash(v, -8);
  end for;
  base64-encode(bytes)
end function;

// Requires the text to round-trip byte-for-byte back to itself through
// re-encoding, exactly the canonical-form check the ALGOL60 reference
// documents: a `ts` that decodes to a value which does not re-encode
// identically is rejected rather than silently accepted.
define function base64-to-ts (text :: <byte-string>) => (value :: false-or(<integer>))
  let bytes = base64-decode(text);
  if (~bytes | bytes.size ~= 8)
    #f
  else
    let value = 0;
    for (i from 7 to 0 by -1)
      value := ash(value, 8) + bytes[i];
    end for;
    if (ts-to-base64(value) = text) value else #f end if
  end if
end function;

define function make-session-id () => (id :: <byte-string>)
  let b = cx-random-bytes(16);
  // Version 4, variant 1 bits, per RFC 4122 -- cosmetic here (Convex does
  // not validate this string's shape), but cheap to get right.
  b[6] := logior(logand(b[6], 15), 64);
  b[8] := logior(logand(b[8], 63), 128);
  let out = make(<stretchy-vector>);
  let digits = "0123456789abcdef";
  for (i from 0 below 16)
    if (member?(i, #(4, 6, 8, 10)))
      add!(out, '-');
    end if;
    add!(out, digits[ash(b[i], -4)]);
    add!(out, digits[logand(b[i], 15)]);
  end for;
  let result = make(<byte-string>, size: out.size);
  for (i from 0 below out.size)
    result[i] := out[i];
  end for;
  result
end function;

// -- delivery events queued per subscription --

define class <sync-update> (<object>)
  slot upd-kind :: <symbol>, required-init-keyword: kind:; // #"value" or #"error"
  slot upd-value :: <object> = $json-null, init-keyword: value:;
  slot upd-logs :: false-or(<sequence>) = #f, init-keyword: logs:;
  slot upd-error :: false-or(<convex-error>) = #f, init-keyword: error:;
end class <sync-update>;

define class <subscription> (<object>)
  slot sub-query-id :: <integer>, required-init-keyword: query-id:;
  slot sub-path :: <byte-string>, required-init-keyword: path:;
  slot sub-args :: <string-table>, required-init-keyword: args:;
  slot sub-active? :: <boolean> = #t;
  slot sub-rehydrating? :: <boolean> = #f;
  slot sub-last-value :: <object> = $absent;
  slot sub-queue :: <deque> = make(<deque>);
  slot sub-established? :: <boolean> = #f;
end class <subscription>;

define class <sync-manager> (<object>)
  slot sm-url :: <parsed-url>, required-init-keyword: url:;
  slot sm-session-id :: <byte-string>, required-init-keyword: session-id:;
  slot sm-connection-count :: <integer> = 0;
  slot sm-last-close-reason :: <byte-string> = "InitialConnect";
  slot sm-max-observed-ts :: false-or(<integer>) = #f;
  slot sm-query-set-version :: <integer> = 0;
  slot sm-remote-query-set :: <integer> = 0;
  slot sm-remote-identity :: <integer> = 0;
  slot sm-remote-ts :: <byte-string> = $ts-zero;
  slot sm-connected? :: <boolean> = #f;
  slot sm-conn :: false-or(<connection>) = #f;
  slot sm-reader :: false-or(<ws-reader>) = #f;
  slot sm-backoff-ms :: <integer> = $live-initial-backoff-ms;
  slot sm-reconnect-at-ms :: <integer>, required-init-keyword: reconnect-at:;
  slot sm-subscriptions :: <table> = make(<table>); // query-id -> <subscription>
  slot sm-next-query-id :: <integer> = 0;
  slot sm-auth-token :: false-or(<byte-string>) = #f;
end class <sync-manager>;

define function sync-manager-new (url :: <parsed-url>) => (mgr :: <sync-manager>)
  make(<sync-manager>, url: url, session-id: make-session-id(), reconnect-at: cx-now-ms())
end function;

define function sync-active-subscriptions (mgr :: <sync-manager>) => (subs :: <sequence>)
  let out = make(<stretchy-vector>);
  for (query-id in sm-subscriptions(mgr).key-sequence)
    let sub = element(sm-subscriptions(mgr), query-id);
    if (sub.sub-active?)
      add!(out, sub);
    end if;
  end for;
  out
end function;

// -- outgoing message builders --

define function build-connect-message (mgr :: <sync-manager>) => (text :: <byte-string>)
  let obj = make-json-object();
  json-object-set!(obj, "type", "Connect");
  json-object-set!(obj, "sessionId", mgr.sm-session-id);
  json-object-set!(obj, "connectionCount", mgr.sm-connection-count);
  json-object-set!(obj, "lastCloseReason", mgr.sm-last-close-reason);
  if (mgr.sm-max-observed-ts)
    json-object-set!(obj, "maxObservedTimestamp", ts-to-base64(mgr.sm-max-observed-ts));
  end if;
  json-object-set!(obj, "clientTs", 0);
  json-encode(obj)
end function;

define function build-modify-message
    (mgr :: <sync-manager>, adds :: <sequence>, removes :: <sequence>)
 => (text :: <byte-string>)
  let base-version = mgr.sm-query-set-version;
  let new-version = base-version + 1;
  mgr.sm-query-set-version := new-version;
  let mods = make(<stretchy-vector>);
  for (sub in adds)
    let mod = make-json-object();
    json-object-set!(mod, "type", "Add");
    json-object-set!(mod, "queryId", sub.sub-query-id);
    json-object-set!(mod, "udfPath", sub.sub-path);
    let args-array = make(<stretchy-vector>, size: 1);
    args-array[0] := sub.sub-args;
    json-object-set!(mod, "args", args-array);
    add!(mods, mod);
  end for;
  for (query-id in removes)
    let mod = make-json-object();
    json-object-set!(mod, "type", "Remove");
    json-object-set!(mod, "queryId", query-id);
    add!(mods, mod);
  end for;
  let obj = make-json-object();
  json-object-set!(obj, "type", "ModifyQuerySet");
  json-object-set!(obj, "baseVersion", base-version);
  json-object-set!(obj, "newVersion", new-version);
  json-object-set!(obj, "modifications", mods);
  json-encode(obj)
end function;

// -- connection lifecycle --

define function sync-disconnect (mgr :: <sync-manager>, reason :: <byte-string>) => ()
  if (mgr.sm-conn)
    cx-close(mgr.sm-conn);
  end if;
  mgr.sm-conn := #f;
  mgr.sm-reader := #f;
  mgr.sm-connected? := #f;
  mgr.sm-connection-count := mgr.sm-connection-count + 1;
  mgr.sm-last-close-reason := reason;
  mgr.sm-query-set-version := 0;
  mgr.sm-remote-query-set := 0;
  mgr.sm-remote-identity := 0;
  mgr.sm-remote-ts := $ts-zero;
  for (query-id in sm-subscriptions(mgr).key-sequence)
    let sub = element(sm-subscriptions(mgr), query-id);
    sub.sub-rehydrating? := sub.sub-last-value ~== $absent;
    sub.sub-established? := #f;
  end for;
end function;

// Publishes a structured error to every subscription still established
// (or, when established-only? is false, even ones whose initial Add has
// not yet been acknowledged -- used only for the immediate "could not
// connect at all" case, mirroring the reference client's established-only
// distinction for mid-connection transport failures).
define function sync-publish-error-all
    (mgr :: <sync-manager>, name :: <byte-string>, message :: <byte-string>, established-only? :: <boolean>)
 => ()
  for (query-id in sm-subscriptions(mgr).key-sequence)
    let sub = element(sm-subscriptions(mgr), query-id);
    if (sub.sub-active? & (~established-only? | sub.sub-established?))
      sync-enqueue(sub, make(<sync-update>, kind: #"error", error: make-convex-error(name, message)));
    end if;
  end for;
end function;

define function sync-enqueue (sub :: <subscription>, update :: <sync-update>) => ()
  if (sub.sub-queue.size >= $live-max-queue-depth)
    pop(sub.sub-queue); // drop the oldest undelivered event rather than grow unboundedly.
  end if;
  push-last(sub.sub-queue, update);
end function;

define function sync-connect-attempt (mgr :: <sync-manager>, deadline-ms :: <integer>) => ()
  let conn =
    if (mgr.sm-url.url-tls?)
      cx-connect-tls(mgr.sm-url.url-host, mgr.sm-url.url-port, deadline-ms)
    else
      cx-connect-tcp(mgr.sm-url.url-host, mgr.sm-url.url-port, deadline-ms)
    end if;
  if (~conn)
    sync-schedule-retry(mgr, #f);
    sync-publish-error-all(mgr, "TransportError", "could not connect to Convex Live endpoint", #f);
  else
    let path = concatenate(mgr.sm-url.url-path, "/api/sync");
    if (~ws-handshake(conn, mgr.sm-url.url-host, path, deadline-ms))
      cx-close(conn);
      sync-schedule-retry(mgr, #f);
      sync-publish-error-all(mgr, "TransportError", "Live WebSocket handshake failed", #f);
    else
      mgr.sm-conn := conn;
      mgr.sm-reader := ws-open-reader(conn);
      let sent-connect? = ws-send-text(conn, build-connect-message(mgr), deadline-ms);
      let actives = sync-active-subscriptions(mgr);
      let sent-modify? =
        if (actives.size > 0)
          ws-send-text(conn, build-modify-message(mgr, actives, #[]), deadline-ms)
        else
          #t
        end if;
      if (~sent-connect? | ~sent-modify?)
        sync-disconnect(mgr, "TransportError: failed sending Connect/ModifyQuerySet");
        sync-schedule-retry(mgr, #f);
        sync-publish-error-all(mgr, "TransportError", "failed sending initial Live messages", #f);
      else
        mgr.sm-connected? := #t;
        mgr.sm-backoff-ms := $live-initial-backoff-ms;
        for (sub in actives)
          sub.sub-established? := #t;
        end for;
      end if;
    end if;
  end if
end function;

// Advances backoff for the *next* failure (organic path) unless an
// explicit delay is given (the debugDisconnect path, which always
// reconnects after a fixed 100 ms regardless of backoff state).
define function sync-schedule-retry (mgr :: <sync-manager>, explicit-delay-ms :: false-or(<integer>)) => ()
  let delay =
    explicit-delay-ms |
    begin
      let d = mgr.sm-backoff-ms;
      mgr.sm-backoff-ms :=
        if (mgr.sm-backoff-ms < $live-backoff-doubling-limit-ms)
          mgr.sm-backoff-ms * 2
        else
          $live-backoff-cap-ms
        end if;
      d
    end;
  mgr.sm-reconnect-at-ms := cx-now-ms() + delay;
end function;

// -- applying a Transition --

define function apply-transition (mgr :: <sync-manager>, msg :: <string-table>)
 => (ok? :: <boolean>, error-text :: false-or(<byte-string>))
  let start-version = json-object-ref(msg, "startVersion");
  let end-version = json-object-ref(msg, "endVersion");
  let modifications = json-object-ref(msg, "modifications");
  if (~instance?(start-version, <string-table>) | ~instance?(end-version, <string-table>)
        | ~instance?(modifications, <sequence>))
    values(#f, "malformed Transition")
  else
    let start-qs = json-object-ref(start-version, "querySet");
    let start-id = json-object-ref(start-version, "identity");
    let start-ts = json-object-ref(start-version, "ts");
    if (start-qs ~= mgr.sm-remote-query-set | start-id ~= mgr.sm-remote-identity
          | start-ts ~= mgr.sm-remote-ts)
      values(#f, "Transition start version does not match local version")
    else
      // Validate every modification before applying any of them: the
      // whole Transition is accepted or rejected atomically.
      let all-valid? =
        block (invalid)
          for (mod in modifications)
            if (~instance?(mod, <string-table>))
              invalid(#f);
            end if;
            let mtype = json-object-ref(mod, "type");
            let query-id = json-object-ref(mod, "queryId");
            if (~instance?(query-id, <integer>))
              invalid(#f);
            end if;
            if (mtype = "QueryUpdated")
              if (~json-object-has-key?(mod, "value")) invalid(#f) end if;
            elseif (mtype = "QueryFailed")
              if (~instance?(json-object-ref(mod, "errorMessage"), <byte-string>)) invalid(#f) end if;
            elseif (mtype = "QueryRemoved")
              #t;
            else
              invalid(#f);
            end if;
          end for;
          #t
        end block;
      let end-ts = json-object-ref(end-version, "ts");
      let end-ts-value = base64-to-ts(end-ts);
      if (~all-valid?)
        values(#f, "unknown Transition modification")
      elseif (end-ts-value & mgr.sm-remote-ts ~= $ts-zero
            & (base64-to-ts(mgr.sm-remote-ts) | 0) > end-ts-value)
        values(#f, "Live timestamp moved backwards")
      else
        for (mod in modifications)
          let mtype = json-object-ref(mod, "type");
          let query-id = json-object-ref(mod, "queryId");
          let sub = element(mgr.sm-subscriptions, query-id, default: #f);
          if (sub & sub.sub-active?)
            if (mtype = "QueryUpdated")
              let value = json-object-ref(mod, "value");
              let logs = json-object-ref(mod, "logLines");
              let suppress? = sub.sub-rehydrating? & sub.sub-last-value ~== $absent
                                & json-values-equal?(value, sub.sub-last-value);
              sub.sub-rehydrating? := #f;
              if (~suppress?)
                sub.sub-last-value := value;
                sync-enqueue(sub, make(<sync-update>, kind: #"value", value: value,
                                        logs: if (instance?(logs, <sequence>)) logs else #f end if));
              end if;
            elseif (mtype = "QueryFailed")
              sub.sub-rehydrating? := #f;
              let message = json-object-ref(mod, "errorMessage");
              let data = json-object-ref(mod, "errorData");
              let logs = json-object-ref(mod, "logLines");
              let logs-or-f = if (instance?(logs, <sequence>)) logs else #f end if;
              let err = make-convex-error("FunctionError", message, data: data, logs: logs-or-f);
              sync-enqueue(sub, make(<sync-update>, kind: #"error", error: err));
            end if;
            // QueryRemoved is a pure acknowledgement; nothing to deliver.
          end if;
        end for;
        mgr.sm-remote-query-set := json-object-ref(end-version, "querySet");
        mgr.sm-remote-identity := json-object-ref(end-version, "identity");
        mgr.sm-remote-ts := end-ts;
        if (end-ts-value & (~mgr.sm-max-observed-ts | end-ts-value > mgr.sm-max-observed-ts))
          mgr.sm-max-observed-ts := end-ts-value;
        end if;
        values(#t, #f)
      end if;
    end if;
  end if
end function;

define function json-values-equal? (a :: <object>, b :: <object>) => (well? :: <boolean>)
  json-encode(a) = json-encode(b)
end function;

// -- the reactor step --
//
// Waits for either the Live socket to have data (bounded by max-wait-ms,
// itself bounded by the next scheduled reconnect) or the timeout to
// elapse, then does at most one unit of Live work: read+apply one
// message, or attempt a scheduled reconnect. Called from the adapter's
// own main loop between servicing adapter commands.
define function sync-pump (mgr :: <sync-manager>, max-wait-ms :: <integer>) => ()
  let now = cx-now-ms();
  if (mgr.sm-connected? & mgr.sm-conn)
    let wait-ms = min(max-wait-ms, max(0, mgr.sm-reconnect-at-ms - now));
    let revents = cx-poll-wait(mgr.sm-conn.conn-fd, #t, #f, now + wait-ms);
    if (revents > 0)
      let (kind, payload) = ws-recv-message(mgr.sm-reader, now + 2000);
      select (kind)
        #"text" =>
          let (msg, ok?) = json-parse(payload);
          if (~ok? | ~instance?(msg, <string-table>))
            sync-disconnect(mgr, "ProtocolError: malformed Live message");
            sync-schedule-retry(mgr, #f);
            sync-publish-error-all(mgr, "ProtocolError", "received a malformed Live message", #t);
          else
            let mtype = json-object-ref(msg, "type");
            if (mtype = "Transition")
              let (ok2?, err-text) = apply-transition(mgr, msg);
              if (~ok2?)
                sync-disconnect(mgr, concatenate("ProtocolError: ", err-text | "invalid Transition"));
                sync-schedule-retry(mgr, #f);
                sync-publish-error-all(mgr, "ProtocolError", err-text | "invalid Transition", #t);
              end if;
            elseif (mtype = "Ping")
              #f; // no reply required; a real deployment keeps the connection alive itself.
            elseif (mtype = "MutationResponse" | mtype = "ActionResponse")
              #f; // never sent by this client over Live; tolerated defensively.
            else
              let err-value = json-object-ref(msg, "error", default: "");
              sync-disconnect(mgr, concatenate("ProtocolError: unexpected message type"));
              sync-schedule-retry(mgr, #f);
              sync-publish-error-all(mgr, "ProtocolError",
                                      concatenate(if (instance?(mtype, <byte-string>)) mtype else "?" end if,
                                                   ": ",
                                                   if (instance?(err-value, <byte-string>)) err-value else "" end if),
                                      #t);
            end if;
          end if;
        #"close" =>
          sync-disconnect(mgr, "server closed Live WebSocket");
          sync-schedule-retry(mgr, #f);
          sync-publish-error-all(mgr, "TransportError", "server closed Live WebSocket", #t);
        #"error" =>
          sync-disconnect(mgr, "TransportError: Live read failed");
          sync-schedule-retry(mgr, #f);
          sync-publish-error-all(mgr, "TransportError", "Live read failed", #t);
        otherwise => #f;
      end select;
    end if;
  else
    if (now >= mgr.sm-reconnect-at-ms & sync-active-subscriptions(mgr).size > 0)
      sync-connect-attempt(mgr, now + 8000);
    end if;
  end if;
end function;

// -- public operations the adapter drives --

define function sync-subscribe
    (mgr :: <sync-manager>, path :: <byte-string>, args :: <string-table>, deadline-ms :: <integer>)
 => (query-id :: <integer>)
  let query-id = mgr.sm-next-query-id;
  mgr.sm-next-query-id := query-id + 1;
  let sub = make(<subscription>, query-id: query-id, path: path, args: args);
  element(mgr.sm-subscriptions, query-id) := sub;
  if (mgr.sm-connected?)
    ws-send-text(mgr.sm-conn, build-modify-message(mgr, vector(sub), #[]), deadline-ms);
    sub.sub-established? := #t;
  else
    // Not yet connected: sync-pump's next reconnect attempt resends the
    // whole active set, this subscription included.
    sync-pump(mgr, 0);
  end if;
  query-id
end function;

define function sync-unsubscribe (mgr :: <sync-manager>, query-id :: <integer>, deadline-ms :: <integer>) => ()
  let sub = element(mgr.sm-subscriptions, query-id, default: #f);
  if (sub)
    sub.sub-active? := #f;
    if (mgr.sm-connected?)
      ws-send-text(mgr.sm-conn, build-modify-message(mgr, #[], vector(query-id)), deadline-ms);
    end if;
    remove-key!(mgr.sm-subscriptions, query-id);
  end if;
end function;

// Drains at most one pending update for query-id, or #f if none is
// waiting. The adapter calls this after every sync-pump to see whether
// anything needs to be relayed as a "subscription" event.
define function sync-poll-update (mgr :: <sync-manager>, query-id :: <integer>) => (update :: false-or(<sync-update>))
  let sub = element(mgr.sm-subscriptions, query-id, default: #f);
  if (sub & sub.sub-queue.size > 0)
    pop(sub.sub-queue)
  else
    #f
  end if
end function;

define function sync-all-query-ids (mgr :: <sync-manager>) => (ids :: <sequence>)
  sm-subscriptions(mgr).key-sequence
end function;

// Kills the current Live connection (if any) and schedules a reconnect
// after a fixed short delay rather than the organic backoff sequence.
// Runs to completion synchronously -- the old connection is fully retired
// and the reconnect is scheduled before this returns -- so the adapter's
// ack is always correctly ordered relative to both, without needing any
// cross-thread coordination.
define function sync-debug-disconnect (mgr :: <sync-manager>) => (ok? :: <boolean>)
  if (~mgr.sm-connected?)
    #f
  else
    sync-disconnect(mgr, "DebugDisconnect");
    sync-schedule-retry(mgr, $live-debug-reconnect-delay-ms);
    #t
  end if
end function;

define function sync-set-auth (mgr :: <sync-manager>, token :: <byte-string>) => ()
  mgr.sm-auth-token := if (token.size > 0) token else #f end if;
end function;

define function sync-connection-count (mgr :: <sync-manager>) => (n :: <integer>)
  mgr.sm-connection-count
end function;

define function sync-last-close-reason (mgr :: <sync-manager>) => (reason :: <byte-string>)
  mgr.sm-last-close-reason
end function;
