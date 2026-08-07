#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"
staload UN = "prelude/SATS/unsafe.sats"

%{^
#include <string.h>
#include <stdlib.h>

static int c_starts_with(const char *s, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(s, prefix, n) == 0;
}
/* index of the first occurrence of ch in s at or after `from`, or -1 */
static int c_find_char_from(const char *s, char ch, int from) {
    const char *p = strchr(s + from, ch);
    return p == NULL ? -1 : (int) (p - s);
}
static char *c_substring(const char *s, int start, int len) {
    char *out = malloc((size_t) len + 1);
    memcpy(out, s + start, (size_t) len);
    out[len] = '\0';
    return out;
}
static char *c_suffix_from(const char *s, int start) {
    size_t n = strlen(s);
    return c_substring(s, start, (int) n - start);
}
static int c_strlen(const char *s) { return (int) strlen(s); }
static int c_str_to_int(const char *s) { return atoi(s); }
static int c_str_eq(const char *a, const char *b) { return strcmp(a, b) == 0; }
static int c_ends_with_slash(const char *s) {
    size_t n = strlen(s);
    return n > 0 && s[n - 1] == '/';
}
%}

extern fun c_starts_with(s: string, pfx: string): bool = "mac#c_starts_with"
extern fun c_find_char_from(s: string, ch: char, from: int): int = "mac#c_find_char_from"
extern fun c_substring(s: string, start: int, len: int): string = "mac#c_substring"
extern fun c_suffix_from(s: string, start: int): string = "mac#c_suffix_from"
extern fun c_strlen(s: string): int = "mac#c_strlen"
extern fun c_str_to_int(s: string): int = "mac#c_str_to_int"
extern fun c_str_eq(a: string, b: string): bool = "mac#c_str_eq"
extern fun c_ends_with_slash(s: string): bool = "mac#c_ends_with_slash"

(* Reaches the same C helpers convex_json.dats defines (both files are
   combined into one translation unit by `patsopt --dynamics`), rather
   than duplicating string-building C code. *)
extern fun c_concat(a: string, b: string): string = "mac#c_concat"
extern fun c_int_to_string(i: int): string = "mac#c_int_to_string"

fun sc2(a: string, b: string): string = c_concat(a, b)
fun sc3(a: string, b: string, c: string): string = sc2(sc2(a, b), c)

(* ---- client and URL parsing ---- *)

fun client_version_impl(): string = "ats-0.1.0"

implement new_client(url_in) = let
  val n = c_strlen(url_in)
  val url = if c_ends_with_slash(url_in) then c_substring(url_in, 0, n - 1) else url_in
in
  if c_strlen(url) = 0 then CONone
  else if c_starts_with(url, "https://") orelse c_starts_with(url, "http://") then
    COSome(Client(url, SONone))
  else CONone
end

implement set_auth(token, c) = let val Client(url, _) = c in Client(url, SOSome(token)) end
implement clear_auth(c) = let val Client(url, _) = c in Client(url, SONone) end

(* host, port, useTls, basePath *)
datatype hp_opt = HPNone | HPSome of (string, int, bool, string)

fun host_and_path(url: string): hp_opt = let
  val useTls = c_starts_with(url, "https://")
  val schemeLen = if useTls then 8 else 7
  val defaultPort = if useTls then 443 else 80
in
  if not(useTls) andalso not(c_starts_with(url, "http://")) then HPNone
  else let
    val rest = c_suffix_from(url, schemeLen)
    val restLen = c_strlen(rest)
    val slashPos = c_find_char_from(rest, '/', 0)
    val authority = if slashPos < 0 then rest else c_substring(rest, 0, slashPos)
    val basePath = if slashPos < 0 then "" else c_suffix_from(rest, slashPos)
    val authLen = c_strlen(authority)
  in
    if authLen = 0 then HPNone
    else let
      val colonPos = c_find_char_from(authority, ':', 0)
    in
      if colonPos < 0 then HPSome(authority, defaultPort, useTls, basePath)
      else let
        val host = c_substring(authority, 0, colonPos)
        val portText = c_suffix_from(authority, colonPos + 1)
        val port = c_str_to_int(portText)
      in
        if c_strlen(host) = 0 then HPNone else HPSome(host, port, useTls, basePath)
      end
    end
  end
end

fun logs_field(fields: json): strlist =
  case+ json_lookup("logLines", fields) of
  | JOSome(v) => (case+ json_string_list(v) of LOSome(xs) => xs | LONone() => SLNil())
  | JONone() => SLNil()

fun error_data_field(fields: json): json =
  case+ json_lookup("errorData", fields) of JOSome(v) => v | JONone() => JNull()

fun decode_http_response(body: string): call_result = let
  val parsed = parse_json(body)
in
  case+ parsed of
  | JONone() => CallErr(ProtocolErr("Convex HTTP response was not valid JSON"))
  | JOSome(root) => (
      case+ root of
      | JObj(_) => (
          case+ json_lookup("status", root) of
          | JOSome(JStr("success")) => (
              case+ json_lookup("value", root) of
              | JOSome(v) => CallOk(v, logs_field(root))
              | JONone() => CallErr(ProtocolErr("Convex HTTP success response omitted a value"))
            )
          | JOSome(JStr("error")) => (
              case+ json_lookup("errorMessage", root) of
              | JOSome(JStr(msg)) => CallErr(FunctionErr(msg, error_data_field(root), logs_field(root)))
              | _ => CallErr(ProtocolErr("Convex HTTP error response omitted a string errorMessage"))
            )
          | _ => CallErr(ProtocolErr("Convex HTTP response omitted a recognised status"))
        )
      | _ => CallErr(ProtocolErr("Convex HTTP response was not a JSON object"))
    )
end

fun http_call(operation: string, c: client, path: string, args: json): call_result = let
  val Client(url, auth) = c
in
  case+ host_and_path(url) of
  | HPNone() => CallErr(ProtocolErr("Convex deployment URL omitted a host"))
  | HPSome(host, port, useTls, basePath) => let
      val (conn, status, errmsg) = tls_open(host, port, useTls)
    in
      if status <> TLS_OK then CallErr(TransportErr(errmsg))
      else let
        val reqBody = json_to_string(jobj3("path", JStr(path), "args", args, "format", JStr("json")))
        val authHeader = (case+ auth of
          | SOSome(tok) => sc3("Authorization: Bearer ", tok, "\r\n")
          | SONone() => "")
        val request = sc2(
          sc2(
            sc2(sc2("POST ", basePath), sc2(sc2("/api/", operation), " HTTP/1.1\r\n")),
            sc3("Host: ", host, "\r\nContent-Type: application/json\r\nAccept: application/json\r\n")
          ),
          sc2(
            sc2("Connection: close\r\nConvex-Client: ", client_version_impl()),
            sc2(
              sc2("\r\n", authHeader),
              sc3("Content-Length: ", c_int_to_string(c_strlen(reqBody)), sc2("\r\n\r\n", reqBody))
            )
          )
        )
        val (wstatus, werrmsg) = tls_write(conn, request)
        val result =
          if wstatus <> TLS_OK then CallErr(TransportErr(werrmsg))
          else let
            val (rstatus, _httpStatus, body, rerrmsg) = tls_read_http_response(conn)
          in
            if rstatus <> TLS_OK then CallErr(TransportErr(rerrmsg))
            else decode_http_response(body)
          end
        val () = tls_close(conn)
      in
        result
      end
    end
end

implement http_query(c, path, args) = http_call("query", c, path, args)
implement http_mutation(c, path, args) = http_call("mutation", c, path, args)
implement http_action(c, path, args) = http_call("action", c, path, args)

implement error_message(e) =
  case+ e of
  | FunctionErr(msg, _, _) => msg
  | ProtocolErr(msg) => msg
  | TransportErr(msg) => msg

(* ---- Live ---- *)

extern fun c_int_to_double(i: int): double = "mac#c_int_to_double"
extern fun c_double_to_int(d: double): int = "mac#c_double_to_int"

fun jnum(i: int): json = JNum(c_int_to_double(i))

fun initial_live_state(): live_state = LiveState(0, 0, 0, "AAAAAAAAAAA=", 0, ALNil())

implement live_fd(conn) = let val LiveConn(c) = conn in tls_fd(c) end
implement live_close(conn) = let val LiveConn(c) = conn in tls_close(c) end

implement live_connect(c) = let
  val Client(url, _auth) = c
in
  case+ host_and_path(url) of
  | HPNone() => LiveErr(ProtocolErr("Convex deployment URL omitted a host"))
  | HPSome(host, port, useTls, _basePath) => let
      val (conn, status, errmsg) = tls_open(host, port, useTls)
    in
      if status <> TLS_OK then LiveErr(TransportErr(errmsg))
      else let
        val (hsStatus, hsErr) = ws_handshake(conn, host, "/api/sync")
      in
        if hsStatus <> TLS_OK then (tls_close(conn); LiveErr(TransportErr(hsErr)))
        else let
          val sessionId = random_hex(16)
          val connectMsg = jobj5(
            "type", JStr("Connect"),
            "sessionId", JStr(sessionId),
            "connectionCount", jnum(0),
            "lastCloseReason", JNull(),
            "clientTs", jnum(0)
          )
          val (sendStatus, sendErr) = ws_send_text(conn, json_to_string(connectMsg))
        in
          if sendStatus <> TLS_OK then (tls_close(conn); LiveErr(TransportErr(sendErr)))
          else LiveOkConn(LiveConn(conn), initial_live_state())
        end
      end
    end
end

fun modify_query_set_msg(baseVersion: int, newVersion: int, mods: json): json =
  jobj3("type", JStr("ModifyQuerySet"),
        "baseVersion", jnum(baseVersion),
        "newVersion", jnum(newVersion))
  (* modifications is added separately below since jobj3 only takes 3 pairs *)

fun with_mods(msg: json, mods: json): json =
  case+ msg of
  | JObj(fields) => JObj(JFLCons("modifications", mods, fields))
  | _ => msg

fun add_modification(queryId: int, path: string, args: json): json =
  jobj4("type", JStr("Add"), "queryId", jnum(queryId), "udfPath", JStr(path), "args", jarr1(args))

fun remove_modification(queryId: int): json =
  jobj2("type", JStr("Remove"), "queryId", jnum(queryId))

fun live_add_keyed(conn: live_conn, st: live_state, path: string, args: json,
    lastKey: str_opt): add_result = let
  val LiveConn(c) = conn
  val LiveState(qv, rqs, rid, rts, nextId, active) = st
  val newSub = ActiveSub(nextId, path, args, lastKey)
  val newActive = appendActive(active, newSub)
  val msg = with_mods(modify_query_set_msg(qv, qv + 1, JNull()), jarr1(add_modification(nextId, path, args)))
  val (sendStatus, _sendErr) = ws_send_text(c, json_to_string(msg))
in
  if sendStatus = TLS_OK then
    AddOk(nextId, LiveState(qv + 1, rqs, rid, rts, nextId + 1, newActive))
  else
    AddOk(nextId, LiveState(qv, rqs, rid, rts, nextId + 1, active))
end

and appendActive(xs: activelist, s: active_sub): activelist =
  case+ xs of
  | ALNil() => ALCons(s, ALNil())
  | ALCons(h, t) => ALCons(h, appendActive(t, s))

implement live_add(conn, st, path, args) = let
  val AddOk(qid, newSt) = live_add_keyed(conn, st, path, args, SONone())
in
  AddOk(qid, newSt)
end

implement live_add_resubscribe(conn, st, sub) = let
  val ActiveSub(_oldId, path, args, lastKey) = sub
  val AddOk(qid, newSt) = live_add_keyed(conn, st, path, args, lastKey)
in
  ResubOk(qid, newSt)
end

fun removeActive(xs: activelist, qid: int): activelist =
  case+ xs of
  | ALNil() => ALNil()
  | ALCons(ActiveSub(id, p, a, k), t) =>
      if id = qid then t else ALCons(ActiveSub(id, p, a, k), removeActive(t, qid))

implement live_remove(conn, st, query_id) = let
  val LiveConn(c) = conn
  val LiveState(qv, rqs, rid, rts, nextId, active) = st
  val msg = with_mods(modify_query_set_msg(qv, qv + 1, JNull()), jarr1(remove_modification(query_id)))
  val (sendStatus, _e) = ws_send_text(c, json_to_string(msg))
  val newActive = removeActive(active, query_id)
in
  if sendStatus = TLS_OK
    then LiveState(qv + 1, rqs, rid, rts, nextId, newActive)
    else LiveState(qv, rqs, rid, rts, nextId, newActive)
end

implement live_active_list(st) = let val LiveState(_, _, _, _, _, active) = st in active end

(* ---- Transition validation and delivery ---- *)

datatype version_opt = VONone | VOSome of (int, int, string)  (* querySet, identity, ts *)

fun parse_version(j: json): version_opt =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("querySet", j) of
      | JOSome(qsj) => (case+ json_integral_int(qsj) of
          | IOSome(qs) => (
              case+ json_lookup("identity", j) of
              | JOSome(idj) => (case+ json_integral_int(idj) of
                  | IOSome(idn) => (
                      case+ json_lookup("ts", j) of
                      | JOSome(JStr(ts)) => VOSome(qs, idn, ts)
                      | _ => VONone()
                    )
                  | IONone() => VONone()
                )
              | JONone() => VONone()
            )
          | IONone() => VONone()
        )
      | JONone() => VONone()
    )
  | _ => VONone()

fun ts_value(ts: string): lint = let
  val (ok, v) = base64_decode_ts8(ts)
in
  if ok then v else 0L
end

(* One parsed sync-protocol modification, before coalescing. *)
datatype pmod =
  | PMUpdated of (int, json, strlist)
  | PMFailed of (int, string, json, strlist)
  | PMRemoved of int

fun pmod_id(m: pmod): int =
  case+ m of PMUpdated(i, _, _) => i | PMFailed(i, _, _, _) => i | PMRemoved(i) => i

datatype pmodlist = PMLNil | PMLCons of (pmod, pmodlist)

fun parse_modification(j: json): pmod =
  case+ j of
  | JObj(_) => let
      val qid = (case+ json_lookup("queryId", j) of
        | JOSome(qj) => (case+ json_integral_int(qj) of IOSome(n) => n | IONone() => ~1)
        | JONone() => ~1)
      val kind = (case+ json_lookup("type", j) of JOSome(JStr(k)) => k | _ => "")
    in
      if c_str_eq(kind, "QueryUpdated") then (
        case+ json_lookup("value", j) of
        | JOSome(v) => PMUpdated(qid, v, logs_field(j))
        | JONone() => PMRemoved(~1)
      ) else if c_str_eq(kind, "QueryFailed") then (
        case+ json_lookup("errorMessage", j) of
        | JOSome(JStr(msg)) => PMFailed(qid, msg, error_data_field(j), logs_field(j))
        | _ => PMRemoved(~1)
      ) else if c_str_eq(kind, "QueryRemoved") then PMRemoved(qid)
      else PMRemoved(~1)
    end
  | _ => PMRemoved(~1)

fun parse_modifications(j: json): pmodlist =
  case+ j of
  | JArr(xs) => let
      fun loop(xs: jlist): pmodlist =
        case+ xs of
        | JLNil() => PMLNil()
        | JLCons(x, rest) => PMLCons(parse_modification(x), loop(rest))
    in loop(xs) end
  | _ => PMLNil()

(* Keep only the final modification per queryId, preserving first-seen order
   of surviving ids -- a later entry for the same query fully supersedes an
   earlier one within one Transition. *)
fun coalesce(ms: pmodlist): pmodlist = let
  fun containsId(ms: pmodlist, qid: int): bool =
    case+ ms of
    | PMLNil() => false
    | PMLCons(m, rest) => if pmod_id(m) = qid then true else containsId(rest, qid)
  fun dropId(ms: pmodlist, qid: int): pmodlist =
    case+ ms of
    | PMLNil() => PMLNil()
    | PMLCons(m, rest) => if pmod_id(m) = qid then dropId(rest, qid) else PMLCons(m, dropId(rest, qid))
  fun loop(ms: pmodlist): pmodlist =
    case+ ms of
    | PMLNil() => PMLNil()
    | PMLCons(m, rest) =>
        if containsId(rest, pmod_id(m)) then loop(dropId(rest, pmod_id(m)))
        else PMLCons(m, loop(rest))
in
  loop(ms)
end

fun update_key_value(v: json, logs: strlist): string =
  json_to_string(jobj2("v", v, "n", intlist_to_json(logs)))
and update_key_error(msg: string, edata: json, logs: strlist): string =
  json_to_string(jobj3("e", JStr(msg), "d", edata, "n", intlist_to_json(logs)))
and intlist_to_json(xs: strlist): json =
  case+ xs of
  | SLNil() => JArr(JLNil())
  | SLCons(s, rest) => (case+ intlist_to_json(rest) of JArr(tail) => JArr(JLCons(JStr(s), tail)) | other => other)

datatype active_sub_opt = ASONone | ASOSome of active_sub

fun findActive(xs: activelist, qid: int): active_sub_opt =
  case+ xs of
  | ALNil() => ASONone()
  | ALCons(s, rest) => let val ActiveSub(id, _, _, _) = s in
      if id = qid then ASOSome(s) else findActive(rest, qid)
    end

fun setLastKey(xs: activelist, qid: int, key: str_opt): activelist =
  case+ xs of
  | ALNil() => ALNil()
  | ALCons(ActiveSub(id, p, a, k), rest) =>
      if id = qid then ALCons(ActiveSub(id, p, a, key), rest)
      else ALCons(ActiveSub(id, p, a, k), setLastKey(rest, qid, key))

datatype chg_opt = CGONone | CGOSome of live_change

fun deliverOne(m: pmod, active: activelist): (activelist, chg_opt) =
  case+ m of
  | PMRemoved(qid) => (setLastKey(active, qid, SONone()), CGONone())
  | PMUpdated(qid, v, logs) => let
      val key = update_key_value(v, logs)
    in
      case+ findActive(active, qid) of
      | ASONone() => (active, CGONone())
      | ASOSome(ActiveSub(_, _, _, SOSome(oldKey))) =>
          if c_str_eq(oldKey, key) then (active, CGONone())
          else (setLastKey(active, qid, SOSome(key)), CGOSome(LiveValue(qid, v, logs)))
      | ASOSome(ActiveSub(_, _, _, SONone())) =>
          (setLastKey(active, qid, SOSome(key)), CGOSome(LiveValue(qid, v, logs)))
    end
  | PMFailed(qid, msg, edata, logs) => let
      val key = update_key_error(msg, edata, logs)
    in
      case+ findActive(active, qid) of
      | ASONone() => (active, CGONone())
      | ASOSome(ActiveSub(_, _, _, SOSome(oldKey))) =>
          if c_str_eq(oldKey, key) then (active, CGONone())
          else (setLastKey(active, qid, SOSome(key)), CGOSome(LiveQueryError(qid, FunctionErr(msg, edata, logs), logs)))
      | ASOSome(ActiveSub(_, _, _, SONone())) =>
          (setLastKey(active, qid, SOSome(key)), CGOSome(LiveQueryError(qid, FunctionErr(msg, edata, logs), logs)))
    end

fun deliverAll(ms: pmodlist, active: activelist): (activelist, changelist) =
  case+ ms of
  | PMLNil() => (active, CLNil())
  | PMLCons(m, rest) => let
      val (active1, maybeChg) = deliverOne(m, active)
      val (active2, restChgs) = deliverAll(rest, active1)
    in
      case+ maybeChg of
      | CGONone() => (active2, restChgs)
      | CGOSome(chg) => (active2, CLCons(chg, restChgs))
    end

fun apply_transition(st: live_state, msg: json): live_poll_result = let
  val LiveState(qv, rqs, rid, rts, nextId, active) = st
in
  case+ json_lookup("startVersion", msg) of
  | JONone() => LiveProtocolError("Transition omitted startVersion")
  | JOSome(startJson) => (
      case+ parse_version(startJson) of
      | VONone() => LiveProtocolError("Transition startVersion was malformed")
      | VOSome(sqs, sid, sts) =>
          if sqs <> rqs orelse sid <> rid orelse not(c_str_eq(sts, rts)) then
            LiveProtocolError("Transition startVersion did not match local state")
          else (
            case+ json_lookup("endVersion", msg) of
            | JONone() => LiveProtocolError("Transition omitted endVersion")
            | JOSome(endJson) => (
                case+ parse_version(endJson) of
                | VONone() => LiveProtocolError("Transition endVersion was malformed")
                | VOSome(eqs, eid, ets) =>
                    if eqs < sqs orelse eid < sid orelse ts_value(ets) < ts_value(sts) then
                      LiveProtocolError("Transition endVersion moved backwards")
                    else if eqs > qv then
                      LiveProtocolError("Transition exceeded the locally written query-set version")
                    else (
                      case+ json_lookup("modifications", msg) of
                      | JONone() => LiveProtocolError("Transition omitted modifications")
                      | JOSome(modsJson) => let
                          val mods = coalesce(parse_modifications(modsJson))
                          val (newActive, changes) = deliverAll(mods, active)
                          val newSt = LiveState(qv, eqs, eid, ets, nextId, newActive)
                        in
                          LiveTransition(newSt, changes)
                        end
                    )
              )
          )
    )
end

implement live_poll(conn, st) = let
  val LiveConn(c) = conn
  val (kind, text) = ws_recv(c, 0)
in
  if kind = WS_TIMEOUT then LiveWouldBlock()
  else if kind = WS_PEER_CLOSED then LivePeerClosed()
  else if kind = WS_ERROR then LiveProtocolError(text)
  else (
    case+ parse_json(text) of
    | JONone() => LiveProtocolError("sync message was not valid JSON")
    | JOSome(msg) => (
        case+ json_lookup("type", msg) of
        | JOSome(JStr("Transition")) => apply_transition(st, msg)
        | JOSome(JStr("Ping")) => LivePing()
        | JOSome(JStr("MutationResponse")) => LiveIgnored()
        | JOSome(JStr("ActionResponse")) => LiveIgnored()
        | JOSome(JStr("TransitionChunk")) => LiveProtocolError("TransitionChunk assembly is not implemented")
        | JOSome(JStr(kind)) => LiveProtocolError(sc2("unexpected sync message: ", kind))
        | _ => LiveProtocolError("sync message omitted a string type")
      )
  )
end
