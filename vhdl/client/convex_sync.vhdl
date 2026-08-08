-- convex_sync.vhdl - Convex's pinned `/api/sync` Live protocol: the
-- Connect/ModifyQuerySet/Transition wire messages, on top of
-- convex_ws.vhdl's frame layer. One call stack owns the connection at all
-- times -- there is no second process reading or writing it -- so the
-- "one worker exclusive ownership" this project's Live acceptance rules
-- ask for holds structurally rather than by convention: sync_step is a
-- demand-driven step function a caller polls, not a background worker
-- with its own thread. At most SYNC_MAX_PENDING already-decoded events
-- are held between calls, in a fixed-capacity queue that drops the
-- oldest undelivered event on overflow rather than growing without
-- bound, matching AGENTS.md's bounded-queue requirement.
--
-- Convex query and mutation *calls* stay on plain HTTP
-- (convex_http.vhdl); this file only carries Live query subscriptions.
-- WebSocket-carried mutations/actions, multi-chunk Transition assembly,
-- and Live authentication are not implemented -- see the README's
-- limitations list.
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_json.all;
use work.convex_http.all;
use work.convex_native.all;
use work.convex_ws.all;

package convex_sync is

  constant SYNC_MAX_SUBS      : natural := 8;
  constant SYNC_MAX_PENDING   : natural := 8;
  constant SYNC_SUBID_CAP     : natural := 64;
  constant SYNC_PATH_CAP      : natural := 128;
  constant SYNC_ARGS_CAP      : natural := 512;
  constant SYNC_VALUE_CAP     : natural := 4096;
  constant SYNC_REASON_CAP    : natural := 32;
  constant SYNC_ERRNAME_CAP   : natural := 16;
  constant SYNC_ERRMSG_CAP    : natural := 256;
  constant SYNC_ERRDATA_CAP  : natural := 1024;
  constant SYNC_FRAME_DEADLINE_MS : integer := 5000;
  constant SYNC_INITIAL_BACKOFF_MS : integer := 100;
  constant SYNC_MAX_BACKOFF_MS     : integer := 8000;

  type sync_event_kind_t is (SYNC_UPDATED, SYNC_FAILED, SYNC_CLOSED);

  type sync_sub_t is record
    used                 : boolean;
    id                   : natural;
    sub_id               : byte_array(0 to SYNC_SUBID_CAP - 1);
    sub_id_len           : natural;
    path                 : byte_array(0 to SYNC_PATH_CAP - 1);
    path_len             : natural;
    args_json            : byte_array(0 to SYNC_ARGS_CAP - 1);
    args_len             : natural;
    has_last_value       : boolean;
    last_value           : byte_array(0 to SYNC_VALUE_CAP - 1);
    last_value_len       : natural;
    last_success         : boolean;
    awaiting_rehydration : boolean;
  end record sync_sub_t;

  type sync_sub_array_t is array (0 to SYNC_MAX_SUBS - 1) of sync_sub_t;

  type sync_pending_t is record
    kind          : sync_event_kind_t;
    sub_id        : byte_array(0 to SYNC_SUBID_CAP - 1);
    sub_id_len    : natural;
    value_json    : byte_array(0 to SYNC_VALUE_CAP - 1);
    value_len     : natural;
    logs_json     : byte_array(0 to SYNC_VALUE_CAP - 1);
    logs_len      : natural;
    error_name    : byte_array(0 to SYNC_ERRNAME_CAP - 1);
    error_name_len : natural;
    error_message : byte_array(0 to SYNC_ERRMSG_CAP - 1);
    error_message_len : natural;
    error_data    : byte_array(0 to SYNC_ERRDATA_CAP - 1);
    error_data_len : natural;
  end record sync_pending_t;

  type sync_pending_array_t is array (0 to SYNC_MAX_PENDING - 1) of sync_pending_t;

  type sync_manager_t is record
    ep                  : http_endpoint_t;
    sync_path           : byte_array(0 to HTTP_PATH_CAP + 15);
    sync_path_len       : natural;
    connected           : boolean;
    handle              : integer;
    query_set_version   : natural;
    have_remote_version : boolean;
    remote_query_set    : natural;
    remote_identity     : natural;
    remote_ts           : byte_array(0 to 7);
    next_query_id       : natural;
    connection_count    : natural;
    last_close_reason   : byte_array(0 to SYNC_REASON_CAP - 1);
    last_close_reason_len : natural;
    have_max_ts         : boolean;
    max_ts              : byte_array(0 to 7);
    retry_delay_ms      : integer;
    next_attempt_ms     : real;
    subs                : sync_sub_array_t;
    pending             : sync_pending_array_t;
    pending_count       : natural;
  end record sync_manager_t;

  -- Initializes m for a fresh client against ep. Must be called once
  -- before any other sync_ procedure.
  procedure sync_init(m : inout sync_manager_t; ep : in http_endpoint_t);

  -- Registers (or replaces) one subscription. A prior subscription under
  -- the same subscription_id is retired -- its Remove is sent, if
  -- connected -- before the new one is added.
  procedure sync_subscribe(
    signal rq   : inout xport_req_t;
    m           : inout sync_manager_t;
    sub_id      : in string;
    path        : in string;
    args_json   : in byte_array;
    args_len    : in natural;
    ok          : out boolean
  );

  procedure sync_unsubscribe(
    signal rq  : inout xport_req_t;
    m          : inout sync_manager_t;
    sub_id     : in string;
    ok         : out boolean
  );

  -- Adapter-only: closes the active Live connection immediately. Active
  -- subscriptions are left registered so the next successful connect
  -- replays their Add.
  procedure sync_debug_disconnect(
    signal rq : inout xport_req_t;
    m         : inout sync_manager_t;
    ok        : out boolean
  );

  -- Advances the Live connection by at most one step: reconnecting (with
  -- exponential backoff) if there are active subscriptions but no
  -- socket, or waiting up to poll_timeout_ms for the next frame and
  -- handling it. has_event is true when an event was delivered into the
  -- out parameters below; false is a normal outcome (nothing arrived
  -- within the timeout), not a failure. ok is only false for a
  -- programming-level condition (an oversized value this checkpoint's
  -- fixed buffers cannot hold); ordinary connection failures are surfaced
  -- as a SYNC_FAILED "TransportError" event to every active subscription
  -- instead.
  procedure sync_step(
    signal rq         : inout xport_req_t;
    m                 : inout sync_manager_t;
    poll_timeout_ms   : in integer;
    has_event         : out boolean;
    kind              : out sync_event_kind_t;
    sub_id            : inout byte_array;
    sub_id_len        : out natural;
    value_json        : inout byte_array;
    value_len         : out natural;
    logs_json         : inout byte_array;
    logs_len          : out natural;
    error_name        : inout byte_array;
    error_name_len    : out natural;
    error_message     : inout byte_array;
    error_message_len : out natural;
    error_data        : inout byte_array;
    error_data_len    : out natural;
    ok                : out boolean
  );

end package convex_sync;

package body convex_sync is

  function bytes_eq(
    a : byte_array; aoff, alen : natural;
    b : byte_array; boff, blen : natural
  ) return boolean is
  begin
    if alen /= blen then
      return false;
    end if;
    for i in 0 to alen - 1 loop
      if a(a'low + aoff + i) /= b(b'low + boff + i) then
        return false;
      end if;
    end loop;
    return true;
  end function bytes_eq;

  -- Little-endian 8-byte timestamp compare: the most significant byte to
  -- compare first is the last one. Returns -1, 0 or 1.
  function timestamp_compare(a : byte_array; b : byte_array) return integer is
  begin
    for i in 7 downto 0 loop
      if a(a'low + i) < b(b'low + i) then
        return -1;
      end if;
      if a(a'low + i) > b(b'low + i) then
        return 1;
      end if;
    end loop;
    return 0;
  end function timestamp_compare;

  function b64_val(c : byte_t) return integer is
  begin
    if c >= character'pos('A') and c <= character'pos('Z') then
      return c - character'pos('A');
    elsif c >= character'pos('a') and c <= character'pos('z') then
      return c - character'pos('a') + 26;
    elsif c >= character'pos('0') and c <= character'pos('9') then
      return c - character'pos('0') + 52;
    elsif c = character'pos('+') then
      return 62;
    elsif c = character'pos('/') then
      return 63;
    end if;
    return -1;
  end function b64_val;

  -- Decodes exactly the canonical 12-character base64 (one trailing '=')
  -- encoding of an 8-byte timestamp that this pinned sync profile uses.
  procedure timestamp_decode(buf : byte_array; off, blen : natural; outbytes : inout byte_array; ok : out boolean) is
    variable v0, v1, v2, v3 : integer;
    variable n_out : natural := 0;
  begin
    ok := false;
    if blen /= 12 then
      return;
    end if;
    for g in 0 to 2 loop
      v0 := b64_val(buf(buf'low + off + g * 4));
      v1 := b64_val(buf(buf'low + off + g * 4 + 1));
      v2 := b64_val(buf(buf'low + off + g * 4 + 2));
      v3 := b64_val(buf(buf'low + off + g * 4 + 3));
      if v0 < 0 or v1 < 0 then
        return;
      end if;
      outbytes(outbytes'low + n_out) := v0 * 4 + v1 / 16;
      n_out := n_out + 1;
      if v2 >= 0 then
        outbytes(outbytes'low + n_out) := (v1 mod 16) * 16 + v2 / 4;
        n_out := n_out + 1;
        if v3 >= 0 then
          outbytes(outbytes'low + n_out) := (v2 mod 4) * 64 + v3;
          n_out := n_out + 1;
        end if;
      end if;
    end loop;
    ok := n_out = 8;
  end procedure timestamp_decode;

  procedure sync_init(m : inout sync_manager_t; ep : in http_endpoint_t) is
  begin
    m.ep := ep;
    m.sync_path_len := 0;
    buf_put_slice(m.sync_path, m.sync_path_len, ep.base_path, 0, ep.base_path_len);
    buf_put_str(m.sync_path, m.sync_path_len, "/api/sync");
    m.connected := false;
    m.handle := -1;
    m.query_set_version := 0;
    m.have_remote_version := false;
    m.remote_query_set := 0;
    m.remote_identity := 0;
    m.next_query_id := 0;
    m.connection_count := 0;
    m.last_close_reason_len := 0;
    buf_put_str(m.last_close_reason, m.last_close_reason_len, "InitialConnect");
    m.have_max_ts := false;
    m.retry_delay_ms := SYNC_INITIAL_BACKOFF_MS;
    m.next_attempt_ms := 0.0;
    m.pending_count := 0;
    for i in 0 to SYNC_MAX_SUBS - 1 loop
      m.subs(i).used := false;
    end loop;
  end procedure sync_init;

  procedure close_socket(signal rq : inout xport_req_t; m : inout sync_manager_t; reason : in string) is
    variable r : integer;
  begin
    if m.connected then
      xport_call(rq, CMD_CLOSE, m.handle, 0, r);
      m.connected := false;
    end if;
    m.last_close_reason_len := 0;
    buf_put_str(m.last_close_reason, m.last_close_reason_len, reason);
  end procedure close_socket;

  -- Appends one event, dropping the oldest pending event first if the
  -- queue is already full.
  procedure push_pending(m : inout sync_manager_t; ev : in sync_pending_t) is
  begin
    if m.pending_count >= SYNC_MAX_PENDING then
      for i in 0 to SYNC_MAX_PENDING - 2 loop
        m.pending(i) := m.pending(i + 1);
      end loop;
      m.pending(SYNC_MAX_PENDING - 1) := ev;
    else
      m.pending(m.pending_count) := ev;
      m.pending_count := m.pending_count + 1;
    end if;
  end procedure push_pending;

  procedure publish_owner_error(m : inout sync_manager_t; name : in string; message : in string) is
    variable ev : sync_pending_t;
  begin
    for i in 0 to SYNC_MAX_SUBS - 1 loop
      if m.subs(i).used then
        ev.kind := SYNC_FAILED;
        ev.sub_id_len := 0;
        buf_put_slice(ev.sub_id, ev.sub_id_len, m.subs(i).sub_id, 0, m.subs(i).sub_id_len);
        ev.value_len := 0;
        ev.logs_len := 0;
        ev.error_name_len := 0;
        buf_put_str(ev.error_name, ev.error_name_len, name);
        ev.error_message_len := 0;
        buf_put_str(ev.error_message, ev.error_message_len, message);
        ev.error_data_len := 0;
        push_pending(m, ev);
      end if;
    end loop;
  end procedure publish_owner_error;

  function find_sub_by_id_str(m : sync_manager_t; sub_id : string) return integer is
  begin
    for i in 0 to SYNC_MAX_SUBS - 1 loop
      if m.subs(i).used and buf_eq_str(m.subs(i).sub_id, 0, m.subs(i).sub_id_len, sub_id) then
        return i;
      end if;
    end loop;
    return -1;
  end function find_sub_by_id_str;

  function find_sub_by_query_id(m : sync_manager_t; qid : natural) return integer is
  begin
    for i in 0 to SYNC_MAX_SUBS - 1 loop
      if m.subs(i).used and m.subs(i).id = qid then
        return i;
      end if;
    end loop;
    return -1;
  end function find_sub_by_query_id;

  function find_free_slot(m : sync_manager_t) return integer is
  begin
    for i in 0 to SYNC_MAX_SUBS - 1 loop
      if not m.subs(i).used then
        return i;
      end if;
    end loop;
    return -1;
  end function find_free_slot;

  procedure send_json_text(
    signal rq : inout xport_req_t;
    m         : inout sync_manager_t;
    buf       : in byte_array;
    len       : in natural;
    ok        : out boolean
  ) is
  begin
    ws_write_frame(rq, m.handle, WS_TEXT, buf, len, ok);
    if not ok then
      close_socket(rq, m, "write failed");
    end if;
  end procedure send_json_text;

  -- Sends one ModifyQuerySet with a single Add or Remove modification,
  -- and advances query_set_version, matching hare and this project's
  -- other native clients: every subscription change is its own message
  -- rather than batched with any other pending change.
  procedure send_modify(
    signal rq  : inout xport_req_t;
    m          : inout sync_manager_t;
    slot       : in integer;
    is_add     : in boolean;
    ok         : out boolean
  ) is
    variable buf : byte_array(0 to SYNC_ARGS_CAP + SYNC_PATH_CAP + 128);
    variable len : natural := 0;
    variable base, next_v : natural;
  begin
    base := m.query_set_version;
    next_v := base + 1;
    buf_put_byte(buf, len, character'pos('{'));
    json_put_string(buf, len, "type");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_string(buf, len, "ModifyQuerySet");
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "baseVersion");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_int(buf, len, base);
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "newVersion");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_int(buf, len, next_v);
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "modifications");
    buf_put_byte(buf, len, character'pos(':'));
    buf_put_byte(buf, len, character'pos('['));
    buf_put_byte(buf, len, character'pos('{'));
    json_put_string(buf, len, "type");
    buf_put_byte(buf, len, character'pos(':'));
    if is_add then
      json_put_string(buf, len, "Add");
    else
      json_put_string(buf, len, "Remove");
    end if;
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "queryId");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_int(buf, len, m.subs(slot).id);
    if is_add then
      buf_put_byte(buf, len, character'pos(','));
      json_put_string(buf, len, "udfPath");
      buf_put_byte(buf, len, character'pos(':'));
      json_put_string_bytes(buf, len, m.subs(slot).path, 0, m.subs(slot).path_len);
      buf_put_byte(buf, len, character'pos(','));
      json_put_string(buf, len, "args");
      buf_put_byte(buf, len, character'pos(':'));
      buf_put_byte(buf, len, character'pos('['));
      buf_put_slice(buf, len, m.subs(slot).args_json, 0, m.subs(slot).args_len);
      buf_put_byte(buf, len, character'pos(']'));
    end if;
    buf_put_byte(buf, len, character'pos('}'));
    buf_put_byte(buf, len, character'pos(']'));
    buf_put_byte(buf, len, character'pos('}'));

    send_json_text(rq, m, buf, len, ok);
    if ok then
      m.query_set_version := next_v;
    end if;
  end procedure send_modify;

  procedure send_connect(signal rq : inout xport_req_t; m : inout sync_manager_t; ok : out boolean) is
    variable buf : byte_array(0 to 511);
    variable len : natural := 0;
    variable session_raw : byte_array(0 to 15);
    variable rnd : integer;
    variable maxts_b64 : byte_array(0 to 15);
    variable maxts_b64_len : natural := 0;
  begin
    ok := false;
    for i in 0 to 15 loop
      xport_call(rq, CMD_RANDOM_BYTE, 0, 0, rnd);
      if rnd < 0 then
        return;
      end if;
      session_raw(i) := rnd;
    end loop;
    -- RFC 4122 version 4 / variant bits.
    session_raw(6) := (session_raw(6) mod 16) + 64;
    session_raw(8) := (session_raw(8) mod 64) + 128;

    buf_put_byte(buf, len, character'pos('{'));
    json_put_string(buf, len, "type");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_string(buf, len, "Connect");
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "sessionId");
    buf_put_byte(buf, len, character'pos(':'));
    buf_put_byte(buf, len, character'pos('"'));
    buf_put_hex(buf, len, session_raw, 0, 4);
    buf_put_byte(buf, len, character'pos('-'));
    buf_put_hex(buf, len, session_raw, 4, 2);
    buf_put_byte(buf, len, character'pos('-'));
    buf_put_hex(buf, len, session_raw, 6, 2);
    buf_put_byte(buf, len, character'pos('-'));
    buf_put_hex(buf, len, session_raw, 8, 2);
    buf_put_byte(buf, len, character'pos('-'));
    buf_put_hex(buf, len, session_raw, 10, 6);
    buf_put_byte(buf, len, character'pos('"'));
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "connectionCount");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_int(buf, len, m.connection_count);
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "lastCloseReason");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_string_bytes(buf, len, m.last_close_reason, 0, m.last_close_reason_len);
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "clientTs");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_int(buf, len, 0);
    if m.have_max_ts then
      buf_put_byte(buf, len, character'pos(','));
      json_put_string(buf, len, "maxObservedTimestamp");
      buf_put_byte(buf, len, character'pos(':'));
      buf_put_base64(maxts_b64, maxts_b64_len, m.max_ts, 0, 8);
      json_put_string_bytes(buf, len, maxts_b64, 0, maxts_b64_len);
    end if;
    buf_put_byte(buf, len, character'pos('}'));

    send_json_text(rq, m, buf, len, ok);
  end procedure send_connect;

  procedure ensure_connected(signal rq : inout xport_req_t; m : inout sync_manager_t; ok : out boolean) is
    variable connect_ok : boolean;
  begin
    ok := false;
    http_connect(rq, m.ep, m.handle, connect_ok);
    if not connect_ok then
      return;
    end if;
    ws_handshake(rq, m.handle, m.ep, "/api/sync", SYNC_FRAME_DEADLINE_MS, connect_ok);
    if not connect_ok then
      return;
    end if;
    m.connected := true;
    m.query_set_version := 0;
    m.have_remote_version := true;
    m.remote_query_set := 0;
    m.remote_identity := 0;
    for i in 0 to 7 loop
      m.remote_ts(i) := 0;
    end loop;

    send_connect(rq, m, connect_ok);
    if not connect_ok then
      return;
    end if;
    if m.connection_count < natural'high then
      m.connection_count := m.connection_count + 1;
    end if;

    for i in 0 to SYNC_MAX_SUBS - 1 loop
      if m.subs(i).used then
        m.subs(i).awaiting_rehydration := m.subs(i).last_success;
        send_modify(rq, m, i, true, connect_ok);
        if not connect_ok then
          return;
        end if;
      end if;
    end loop;
    ok := true;
  end procedure ensure_connected;

  procedure sync_subscribe(
    signal rq   : inout xport_req_t;
    m           : inout sync_manager_t;
    sub_id      : in string;
    path        : in string;
    args_json   : in byte_array;
    args_len    : in natural;
    ok          : out boolean
  ) is
    variable existing : integer;
    variable slot : integer;
    variable send_ok : boolean;
  begin
    ok := false;
    existing := find_sub_by_id_str(m, sub_id);
    if existing >= 0 then
      if m.connected then
        send_modify(rq, m, existing, false, send_ok);
      end if;
      m.subs(existing).used := false;
    end if;

    slot := find_free_slot(m);
    if slot < 0 then
      return; -- too many active Live subscriptions for this checkpoint
    end if;
    if sub_id'length > SYNC_SUBID_CAP or path'length > SYNC_PATH_CAP or args_len > SYNC_ARGS_CAP then
      return;
    end if;

    m.subs(slot).used := true;
    m.subs(slot).id := m.next_query_id;
    m.next_query_id := m.next_query_id + 1;
    m.subs(slot).sub_id_len := 0;
    buf_put_str(m.subs(slot).sub_id, m.subs(slot).sub_id_len, sub_id);
    m.subs(slot).path_len := 0;
    buf_put_str(m.subs(slot).path, m.subs(slot).path_len, path);
    m.subs(slot).args_len := 0;
    buf_put_slice(m.subs(slot).args_json, m.subs(slot).args_len, args_json, 0, args_len);
    m.subs(slot).has_last_value := false;
    m.subs(slot).last_value_len := 0;
    m.subs(slot).last_success := false;
    m.subs(slot).awaiting_rehydration := false;

    if m.connected then
      send_modify(rq, m, slot, true, send_ok);
      if not send_ok then
        return;
      end if;
    end if;
    ok := true;
  end procedure sync_subscribe;

  procedure sync_unsubscribe(
    signal rq  : inout xport_req_t;
    m          : inout sync_manager_t;
    sub_id     : in string;
    ok         : out boolean
  ) is
    variable slot : integer;
    variable send_ok : boolean;
  begin
    slot := find_sub_by_id_str(m, sub_id);
    if slot < 0 then
      ok := true;
      return;
    end if;
    if m.connected then
      send_modify(rq, m, slot, false, send_ok);
    end if;
    m.subs(slot).used := false;
    ok := true;
  end procedure sync_unsubscribe;

  procedure sync_debug_disconnect(
    signal rq : inout xport_req_t;
    m         : inout sync_manager_t;
    ok        : out boolean
  ) is
  begin
    if not m.connected then
      ok := false;
      return;
    end if;
    close_socket(rq, m, "DebugDisconnect");
    ok := true;
  end procedure sync_debug_disconnect;

  procedure deliver_first_pending(
    m                 : inout sync_manager_t;
    has_event         : out boolean;
    kind              : out sync_event_kind_t;
    sub_id            : inout byte_array;
    sub_id_len        : out natural;
    value_json        : inout byte_array;
    value_len         : out natural;
    logs_json         : inout byte_array;
    logs_len          : out natural;
    error_name        : inout byte_array;
    error_name_len    : out natural;
    error_message     : inout byte_array;
    error_message_len : out natural;
    error_data        : inout byte_array;
    error_data_len    : out natural
  ) is
    variable ev : sync_pending_t;
  begin
    has_event := false;
    if m.pending_count = 0 then
      return;
    end if;
    ev := m.pending(0);
    for i in 0 to m.pending_count - 2 loop
      m.pending(i) := m.pending(i + 1);
    end loop;
    m.pending_count := m.pending_count - 1;

    kind := ev.kind;
    sub_id_len := 0;
    buf_put_slice(sub_id, sub_id_len, ev.sub_id, 0, ev.sub_id_len);
    value_len := 0;
    buf_put_slice(value_json, value_len, ev.value_json, 0, ev.value_len);
    logs_len := 0;
    buf_put_slice(logs_json, logs_len, ev.logs_json, 0, ev.logs_len);
    error_name_len := 0;
    buf_put_slice(error_name, error_name_len, ev.error_name, 0, ev.error_name_len);
    error_message_len := 0;
    buf_put_slice(error_message, error_message_len, ev.error_message, 0, ev.error_message_len);
    error_data_len := 0;
    buf_put_slice(error_data, error_data_len, ev.error_data, 0, ev.error_data_len);
    has_event := true;
  end procedure deliver_first_pending;

  -- Decodes {"querySet":<int>,"identity":<int>,"ts":"<base64>"} from an
  -- OBJECT token into its three fields. ok is false if the shape does
  -- not match.
  procedure decode_state_version(
    buf        : in byte_array;
    toks       : in json_tok_array;
    ntoks      : in natural;
    obj_tok    : in integer;
    query_set  : out natural;
    identity   : out natural;
    ts         : inout byte_array;
    ok         : out boolean
  ) is
    variable t : integer;
    variable found : boolean;
    variable v : integer;
    variable iok : boolean;
    variable ts_str : byte_array(0 to 15);
    variable ts_len : natural;
  begin
    ok := false;
    query_set := 0;
    identity := 0;
    json_object_get(buf, toks, ntoks, obj_tok, "querySet", t, found);
    if not found then
      return;
    end if;
    json_tok_as_int(buf, toks, t, v, iok);
    if not iok or v < 0 then
      return;
    end if;
    query_set := v;

    json_object_get(buf, toks, ntoks, obj_tok, "identity", t, found);
    if not found then
      return;
    end if;
    json_tok_as_int(buf, toks, t, v, iok);
    if not iok or v < 0 then
      return;
    end if;
    identity := v;

    json_object_get(buf, toks, ntoks, obj_tok, "ts", t, found);
    if not found or toks(t).kind /= JSON_STRING then
      return;
    end if;
    ts_len := 0;
    json_tok_get_str(buf, toks, t, ts_str, ts_len);
    timestamp_decode(ts_str, 0, ts_len, ts, iok);
    ok := iok;
  end procedure decode_state_version;

  procedure handle_transition(
    signal rq   : inout xport_req_t;
    m           : inout sync_manager_t;
    buf         : in byte_array;
    buflen      : in natural;
    toks        : in json_tok_array;
    ntoks       : in natural;
    root        : in integer;
    ok          : out boolean
  ) is
    variable start_qs, start_id, end_qs, end_id : natural;
    variable start_ts, end_ts : byte_array(0 to 7);
    variable sv_ok : boolean;
    variable start_tok, end_tok, mods_tok : integer;
    variable found : boolean;
    variable nmods : natural;
    variable mod_tok, qid_tok, type_tok, val_tok, logs_tok : integer;
    variable qid_val : integer;
    variable qid_ok : boolean;
    variable slot : integer;
    variable raw_start, raw_stop : integer;
    variable ev : sync_pending_t;
    variable is_dup : boolean;
  begin
    ok := false;
    json_object_get(buf, toks, ntoks, root, "startVersion", start_tok, found);
    if not found then
      return;
    end if;
    decode_state_version(buf, toks, ntoks, start_tok, start_qs, start_id, start_ts, sv_ok);
    if not sv_ok then
      return;
    end if;
    json_object_get(buf, toks, ntoks, root, "endVersion", end_tok, found);
    if not found then
      return;
    end if;
    decode_state_version(buf, toks, ntoks, end_tok, end_qs, end_id, end_ts, sv_ok);
    if not sv_ok then
      return;
    end if;

    if not m.have_remote_version then
      return;
    end if;
    if start_qs /= m.remote_query_set or start_id /= m.remote_identity or
       timestamp_compare(start_ts, m.remote_ts) /= 0 then
      return; -- did not chain from the known state version
    end if;
    if end_qs < start_qs or end_qs > m.query_set_version then
      return;
    end if;
    if end_id < start_id or timestamp_compare(end_ts, start_ts) < 0 then
      return; -- moved backward in time
    end if;

    json_object_get(buf, toks, ntoks, root, "modifications", mods_tok, found);
    if not found or toks(mods_tok).kind /= JSON_ARRAY then
      return;
    end if;

    m.remote_query_set := end_qs;
    m.remote_identity := end_id;
    m.remote_ts := end_ts;
    m.retry_delay_ms := SYNC_INITIAL_BACKOFF_MS;
    if not m.have_max_ts or timestamp_compare(end_ts, m.max_ts) > 0 then
      m.have_max_ts := true;
      m.max_ts := end_ts;
    end if;

    nmods := json_child_count(toks, ntoks, mods_tok);
    for i in 0 to nmods - 1 loop
      mod_tok := json_array_nth(toks, ntoks, mods_tok, i);
      json_object_get(buf, toks, ntoks, mod_tok, "queryId", qid_tok, found);
      if not found then
        return;
      end if;
      json_tok_as_int(buf, toks, qid_tok, qid_val, qid_ok);
      if not qid_ok or qid_val < 0 then
        return;
      end if;
      slot := find_sub_by_query_id(m, qid_val);
      if slot >= 0 then
        json_object_get(buf, toks, ntoks, mod_tok, "type", type_tok, found);
        if not found or toks(type_tok).kind /= JSON_STRING then
          return;
        end if;
        if json_tok_eq_str(buf, toks, type_tok, "QueryUpdated") then
          json_object_get(buf, toks, ntoks, mod_tok, "value", val_tok, found);
          if not found then
            return;
          end if;
          if toks(val_tok).kind = JSON_STRING then
            raw_start := toks(val_tok).start - 1;
            raw_stop := toks(val_tok).stop + 1;
          else
            raw_start := toks(val_tok).start;
            raw_stop := toks(val_tok).stop;
          end if;
          is_dup := m.subs(slot).awaiting_rehydration and m.subs(slot).last_success and
                    m.subs(slot).has_last_value and
                    bytes_eq(m.subs(slot).last_value, 0, m.subs(slot).last_value_len,
                             buf, raw_start, raw_stop - raw_start);
          m.subs(slot).awaiting_rehydration := false;
          if not is_dup then
            m.subs(slot).last_value_len := 0;
            buf_put_slice(m.subs(slot).last_value, m.subs(slot).last_value_len, buf, raw_start, raw_stop - raw_start);
            m.subs(slot).has_last_value := true;
            m.subs(slot).last_success := true;

            ev.kind := SYNC_UPDATED;
            ev.sub_id_len := 0;
            buf_put_slice(ev.sub_id, ev.sub_id_len, m.subs(slot).sub_id, 0, m.subs(slot).sub_id_len);
            ev.value_len := 0;
            buf_put_slice(ev.value_json, ev.value_len, buf, raw_start, raw_stop - raw_start);
            ev.logs_len := 0;
            json_object_get(buf, toks, ntoks, mod_tok, "logLines", logs_tok, found);
            if found then
              buf_put_slice(ev.logs_json, ev.logs_len, buf,
                             toks(logs_tok).start, toks(logs_tok).stop - toks(logs_tok).start);
            else
              buf_put_str(ev.logs_json, ev.logs_len, "[]");
            end if;
            ev.error_name_len := 0;
            ev.error_message_len := 0;
            ev.error_data_len := 0;
            push_pending(m, ev);
          end if;
        elsif json_tok_eq_str(buf, toks, type_tok, "QueryFailed") then
          m.subs(slot).awaiting_rehydration := false;
          m.subs(slot).last_success := false;
          ev.kind := SYNC_FAILED;
          ev.sub_id_len := 0;
          buf_put_slice(ev.sub_id, ev.sub_id_len, m.subs(slot).sub_id, 0, m.subs(slot).sub_id_len);
          ev.value_len := 0;
          ev.error_name_len := 0;
          buf_put_str(ev.error_name, ev.error_name_len, "FunctionError");
          ev.error_message_len := 0;
          json_object_get(buf, toks, ntoks, mod_tok, "errorMessage", val_tok, found);
          if found and toks(val_tok).kind = JSON_STRING then
            json_tok_get_str(buf, toks, val_tok, ev.error_message, ev.error_message_len);
          else
            buf_put_str(ev.error_message, ev.error_message_len, "query failed");
          end if;
          ev.logs_len := 0;
          json_object_get(buf, toks, ntoks, mod_tok, "logLines", logs_tok, found);
          if found then
            buf_put_slice(ev.logs_json, ev.logs_len, buf,
                           toks(logs_tok).start, toks(logs_tok).stop - toks(logs_tok).start);
          else
            buf_put_str(ev.logs_json, ev.logs_len, "[]");
          end if;
          ev.error_data_len := 0;
          json_object_get(buf, toks, ntoks, mod_tok, "errorData", val_tok, found);
          if found then
            -- Same JSON_STRING quote-widening as the value extraction
            -- above: a ConvexError's structured data payload may itself
            -- be a bare string, not just an object.
            if toks(val_tok).kind = JSON_STRING then
              raw_start := toks(val_tok).start - 1;
              raw_stop := toks(val_tok).stop + 1;
            else
              raw_start := toks(val_tok).start;
              raw_stop := toks(val_tok).stop;
            end if;
            buf_put_slice(ev.error_data, ev.error_data_len, buf, raw_start, raw_stop - raw_start);
          end if;
          push_pending(m, ev);
        elsif not json_tok_eq_str(buf, toks, type_tok, "QueryRemoved") then
          return; -- unrecognized modification type
        end if;
      end if;
    end loop;
    ok := true;
  end procedure handle_transition;

  procedure sync_step(
    signal rq         : inout xport_req_t;
    m                 : inout sync_manager_t;
    poll_timeout_ms   : in integer;
    has_event         : out boolean;
    kind              : out sync_event_kind_t;
    sub_id            : inout byte_array;
    sub_id_len        : out natural;
    value_json        : inout byte_array;
    value_len         : out natural;
    logs_json         : inout byte_array;
    logs_len          : out natural;
    error_name        : inout byte_array;
    error_name_len    : out natural;
    error_message     : inout byte_array;
    error_message_len : out natural;
    error_data        : inout byte_array;
    error_data_len    : out natural;
    ok                : out boolean
  ) is
    variable any_active : boolean;
    variable now : real;
    variable connect_ok : boolean;
    variable ready_mask : integer;
    variable frame_opcode : ws_opcode_t;
    variable frame_payload : byte_array(0 to SYNC_VALUE_CAP * 2 - 1);
    variable frame_len : natural;
    variable frame_ok : boolean;
    variable toks : json_tok_array(0 to 255);
    variable ntoks : natural;
    variable parse_ok : boolean;
    variable type_tok : integer;
    variable found : boolean;
    variable pong_ok : boolean;
    variable trans_ok : boolean;
  begin
    ok := true;
    deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                           logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                           error_data, error_data_len);
    if has_event then
      return;
    end if;

    if not m.connected then
      any_active := false;
      for i in 0 to SYNC_MAX_SUBS - 1 loop
        if m.subs(i).used then
          any_active := true;
        end if;
      end loop;
      if not any_active then
        return;
      end if;
      xport_now_ms(rq, now);
      if now < m.next_attempt_ms then
        return;
      end if;
      ensure_connected(rq, m, connect_ok);
      if not connect_ok then
        if m.connected then
          close_socket(rq, m, "connect failed");
        end if;
        xport_now_ms(rq, now);
        m.next_attempt_ms := now + real(m.retry_delay_ms);
        if m.retry_delay_ms < SYNC_MAX_BACKOFF_MS then
          m.retry_delay_ms := m.retry_delay_ms * 2;
          if m.retry_delay_ms > SYNC_MAX_BACKOFF_MS then
            m.retry_delay_ms := SYNC_MAX_BACKOFF_MS;
          end if;
        end if;
      end if;
      return;
    end if;

    xport_call(rq, CMD_WAIT_READY, m.handle, poll_timeout_ms, ready_mask);
    if ready_mask < 0 then
      close_socket(rq, m, "poll failed");
      publish_owner_error(m, "TransportError", "poll failed while waiting for the Live socket");
      deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                             logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                             error_data, error_data_len);
      return;
    end if;
    if ready_mask = 0 then
      return; -- nothing arrived within this step's timeout: a normal outcome
    end if;

    ws_read_message(rq, m.handle, SYNC_FRAME_DEADLINE_MS, frame_opcode, frame_payload, frame_len, frame_ok);
    if not frame_ok then
      close_socket(rq, m, "read failed");
      publish_owner_error(m, "TransportError", "Live frame read failed");
      deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                             logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                             error_data, error_data_len);
      return;
    end if;
    if frame_opcode = WS_CLOSE then
      close_socket(rq, m, "ServerClose");
      publish_owner_error(m, "TransportError", "ServerClose");
      deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                             logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                             error_data, error_data_len);
      return;
    end if;

    json_parse(frame_payload, frame_len, toks, ntoks, parse_ok);
    if not parse_ok or toks(toks'low).kind /= JSON_OBJECT then
      close_socket(rq, m, "malformed Live JSON frame");
      publish_owner_error(m, "ProtocolError", "malformed Live JSON frame");
      deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                             logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                             error_data, error_data_len);
      return;
    end if;
    json_object_get(frame_payload, toks, ntoks, toks'low, "type", type_tok, found);
    if not found or toks(type_tok).kind /= JSON_STRING then
      close_socket(rq, m, "malformed Live JSON frame");
      publish_owner_error(m, "ProtocolError", "malformed Live JSON frame");
      deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                             logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                             error_data, error_data_len);
      return;
    end if;

    if json_tok_eq_str(frame_payload, toks, type_tok, "Ping") then
      ws_write_frame(rq, m.handle, WS_PONG, frame_payload, 0, pong_ok);
      if not pong_ok then
        close_socket(rq, m, "write failed");
        publish_owner_error(m, "TransportError", "could not answer a Live Ping");
        deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                               logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                               error_data, error_data_len);
      end if;
      return;
    end if;

    if not json_tok_eq_str(frame_payload, toks, type_tok, "Transition") then
      close_socket(rq, m, "unexpected Live message type");
      publish_owner_error(m, "ProtocolError", "unexpected Live message type");
      deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                             logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                             error_data, error_data_len);
      return;
    end if;

    handle_transition(rq, m, frame_payload, frame_len, toks, ntoks, toks'low, trans_ok);
    if not trans_ok then
      close_socket(rq, m, "malformed Live transition");
      publish_owner_error(m, "ProtocolError", "malformed Live transition");
    end if;
    deliver_first_pending(m, has_event, kind, sub_id, sub_id_len, value_json, value_len,
                           logs_json, logs_len, error_name, error_name_len, error_message, error_message_len,
                           error_data, error_data_len);
  end procedure sync_step;

end package body convex_sync;
