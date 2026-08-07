(*
** adapter: the NDJSON adapter protocol v1 executable.
**
** Test infrastructure, not public client code (see AGENTS.md). One
** reactor loop, one poll(2) call per iteration over the control channel
** and the Live socket together, so there is exactly one owner of every
** WebSocket read, write, and reconnect -- the same shape convex.hs and
** convex.m (Haskell and Mercury clients in this project) use for the
** identical reason.
*)
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"
staload "./adapter_logic.sats"
staload UN = "prelude/SATS/unsafe.sats"

%{^
#include <string.h>
#include <stdlib.h>
static int c_streq(const char *a, const char *b) { return strcmp(a, b) == 0; }
static int c_slen(const char *s) { return (int) strlen(s); }
static char *c_getenv_or(const char *name, int *out_present) {
    char *v = getenv(name);
    *out_present = (v != NULL);
    return v != NULL ? v : "";
}
static int c_find_colon(const char *s) {
    const char *p = strchr(s, ':');
    return p == NULL ? -1 : (int) (p - s);
}
static char *c_sub(const char *s, int start, int len) {
    char *out = malloc((size_t) len + 1);
    memcpy(out, s + start, (size_t) len);
    out[len] = '\0';
    return out;
}
static char *c_tail(const char *s, int start) { return c_sub(s, start, (int) strlen(s) - start); }
%}
extern fun c_streq(a: string, b: string): bool = "mac#c_streq"
extern fun c_slen(s: string): int = "mac#c_slen"
extern fun c_getenv_or(name: string, out_present: &int? >> int): string = "mac#c_getenv_or"
extern fun c_find_colon(s: string): int = "mac#c_find_colon"
extern fun c_sub(s: string, start: int, len: int): string = "mac#c_sub"
extern fun c_tail(s: string, start: int): string = "mac#c_tail"
extern fun c_concat(a: string, b: string): string = "mac#c_concat"
extern fun c_int_to_string(i: int): string = "mac#c_int_to_string"
extern fun c_str_to_int(s: string): int = "mac#c_str_to_int"

fun sc2(a: string, b: string): string = c_concat(a, b)

(* ---- adapter state ---- *)

datatype maybe_client = MCNone | MCSome of client
datatype maybe_live = MLNone | MLSome of (live_conn, live_state)

datatype sublist = SubNil | SubCons of (string, int, sublist)  (* subscriptionId, queryId, rest *)

fun sub_find(xs: sublist, sub: string): int_opt =
  case+ xs of
  | SubNil() => IONone()
  | SubCons(s, qid, rest) => if c_streq(s, sub) then IOSome(qid) else sub_find(rest, sub)

fun sub_remove(xs: sublist, sub: string): sublist =
  case+ xs of
  | SubNil() => SubNil()
  | SubCons(s, qid, rest) => if c_streq(s, sub) then rest else SubCons(s, qid, sub_remove(rest, sub))

fun sub_find_by_qid(xs: sublist, qid: int): str_opt =
  case+ xs of
  | SubNil() => SONone()
  | SubCons(s, q, rest) => if q = qid then SOSome(s) else sub_find_by_qid(rest, qid)

fun sub_retarget(xs: sublist, oldId: int, newId: int): sublist =
  case+ xs of
  | SubNil() => SubNil()
  | SubCons(s, qid, rest) =>
      if qid = oldId then SubCons(s, newId, sub_retarget(rest, oldId, newId))
      else SubCons(s, qid, sub_retarget(rest, oldId, newId))

datatype astate = AState of (maybe_client, maybe_live, sublist)

fun ensure_client(st: astate): (astate, str_opt, maybe_client) = let
  val AState(mc, ml, subs) = st
in
  case+ mc of
  | MCSome(_) => (st, SONone(), mc)
  | MCNone() => let
      var present: int
      val urlv = c_getenv_or("CONVEX_URL", present)
    in
      if present = 0 then (st, SOSome("CONVEX_URL is required"), MCNone())
      else (
        case+ new_client(urlv) of
        | COSome(c) => (AState(MCSome(c), ml, subs), SONone(), MCSome(c))
        | CONone() => (st, SOSome("CONVEX_URL is not a valid Convex deployment URL"), MCNone())
      )
    end
end

(* ---- emitting events ---- *)

fun emit(fd: int, j: json): void = let val _ = write_line(fd, json_to_string(j)) in () end

fun emit_error(fd: int, mid: str_opt, msub: str_opt, name: string, message: string): void =
  emit(fd, error_event(mid, msub, name, message, JNull(), SLNil()))

fun emit_convex_error(fd: int, mid: str_opt, msub: str_opt, e: convex_error): void =
  case+ e of
  | FunctionErr(msg, edata, logs) => emit(fd, error_event(mid, msub, "FunctionError", msg, edata, logs))
  | ProtocolErr(msg) => emit_error(fd, mid, msub, "ProtocolError", msg)
  | TransportErr(msg) => emit_error(fd, mid, msub, "TransportError", msg)

fun strlist_to_jarr2(xs: strlist): json =
  case+ xs of
  | SLNil() => JArr(JLNil())
  | SLCons(s, rest) => (case+ strlist_to_jarr2(rest) of JArr(t) => JArr(JLCons(JStr(s), t)) | o => o)

(* ---- command execution ---- *)

fun call_operation(opk: call_op, c: client, path: string, args: json): call_result =
  case+ opk of
  | OpQuery() => http_query(c, path, args)
  | OpMutation() => http_mutation(c, path, args)
  | OpAction() => http_action(c, path, args)

fun execute_hello(fd: int, id: string, st: astate): astate = let
  val body = JObj(JFLCons("protocolVersion", JNum(1.0),
    JFLCons("id", JStr(id),
    JFLCons("type", JStr("ready"),
    JFLCons("language", JStr("ats"),
    JFLCons("implementation", JStr("native-ats2-0.1.0"),
    JFLCons("runtime", JStr("ATS2/Postiats 0.4.2, patscc"), JFLNil())))))))
  val () = emit(fd, body)
in
  st
end

fun execute_call(fd: int, id: string, opk: call_op, path: string, args: json, st0: astate): astate = let
  val (st1, errOpt, mc) = ensure_client(st0)
in
  case+ errOpt of
  | SOSome(msg) => (emit_error(fd, SOSome(id), SONone(), "TransportError", msg); st1)
  | SONone() => let
      val MCSome(c) = mc
      val result = call_operation(opk, c, path, args)
    in
      case+ result of
      | CallOk(v, logs) => (
          emit(fd, jobj4("id", JStr(id), "type", JStr("result"), "value", v, "logs", strlist_to_jarr2(logs)));
          st1
        )
      | CallErr(e) => (emit_convex_error(fd, SOSome(id), SONone(), e); st1)
    end
end

fun execute_set_auth(fd: int, id: string, token: string, st0: astate): astate = let
  val (st1, errOpt, mc) = ensure_client(st0)
in
  case+ errOpt of
  | SOSome(msg) => (emit_error(fd, SOSome(id), SONone(), "TransportError", msg); st1)
  | SONone() => let
      val MCSome(c) = mc
      val AState(_, ml, subs) = st1
      val newClient = if c_slen(token) = 0 then clear_auth(c) else set_auth(token, c)
    in
      emit(fd, jobj2("id", JStr(id), "type", JStr("ack")));
      AState(MCSome(newClient), ml, subs)
    end
end

fun execute_subscribe(fd: int, id: string, sub: string, path: string, args: json, st0: astate): astate = let
  val (st1, errOpt, mc) = ensure_client(st0)
in
  case+ errOpt of
  | SOSome(msg) => (emit_error(fd, SOSome(id), SONone(), "TransportError", msg); st1)
  | SONone() => let
      val MCSome(c) = mc
      val AState(_, ml, subs) = st1
    in
      case+ ml of
      | MLSome(conn, lst) => (
          case+ live_add(conn, lst, path, args) of
          | AddOk(qid, lst2) => (
              emit(fd, jobj2("id", JStr(id), "type", JStr("ack")));
              AState(mc, MLSome(conn, lst2), SubCons(sub, qid, sub_remove(subs, sub)))
            )
          | AddErr(msg) => (emit_error(fd, SOSome(id), SONone(), "TransportError", msg); st1)
        )
      | MLNone() => (
          case+ live_connect(c) of
          | LiveOkConn(conn, lst0) => (
              case+ live_add(conn, lst0, path, args) of
              | AddOk(qid, lst2) => (
                  emit(fd, jobj2("id", JStr(id), "type", JStr("ack")));
                  AState(mc, MLSome(conn, lst2), SubCons(sub, qid, sub_remove(subs, sub)))
                )
              | AddErr(msg) => (emit_error(fd, SOSome(id), SONone(), "TransportError", msg); st1)
            )
          | LiveErr(e) => (emit_convex_error(fd, SOSome(id), SONone(), e); st1)
        )
    end
end

fun execute_unsubscribe(fd: int, id: string, sub: string, st0: astate): astate = let
  val AState(mc, ml, subs) = st0
in
  case+ sub_find(subs, sub) of
  | IONone() => (emit(fd, jobj2("id", JStr(id), "type", JStr("ack"))); st0)
  | IOSome(qid) => (
      case+ ml of
      | MLNone() => (emit(fd, jobj2("id", JStr(id), "type", JStr("ack"))); AState(mc, ml, sub_remove(subs, sub)))
      | MLSome(conn, lst) => let
          val lst2 = live_remove(conn, lst, qid)
        in
          emit(fd, jobj2("id", JStr(id), "type", JStr("ack")));
          AState(mc, MLSome(conn, lst2), sub_remove(subs, sub))
        end
    )
end

fun resubscribe_all(conn: live_conn, actives: activelist, subs: sublist, lst: live_state): (sublist, live_state) =
  case+ actives of
  | ALNil() => (subs, lst)
  | ALCons(sub, rest) => let
      val ActiveSub(oldId, _, _, _) = sub
      val ResubOk(newId, lst1) = live_add_resubscribe(conn, lst, sub)
      val subs1 = sub_retarget(subs, oldId, newId)
    in
      resubscribe_all(conn, rest, subs1, lst1)
    end

fun execute_debug_disconnect(fd: int, id: string, st0: astate): astate = let
  val AState(mc, ml, subs) = st0
in
  case+ ml of
  | MLNone() => (emit_error(fd, SOSome(id), SONone(), "TransportError", "Live is not connected"); st0)
  | MLSome(oldConn, oldLst) => let
      val () = live_close(oldConn)
      val actives = live_active_list(oldLst)
      val MCSome(c) = mc
    in
      case+ live_connect(c) of
      | LiveErr(e) => (emit_convex_error(fd, SOSome(id), SONone(), e); AState(mc, MLNone(), subs))
      | LiveOkConn(newConn, newLst0) => let
          val (subs1, newLst) = resubscribe_all(newConn, actives, subs, newLst0)
        in
          emit(fd, jobj2("id", JStr(id), "type", JStr("ack")));
          AState(mc, MLSome(newConn, newLst), subs1)
        end
    end
end

fun close_resources(st: astate): void =
  case+ st of AState(_, MLSome(conn, _), _) => live_close(conn) | AState(_, MLNone(), _) => ()

fun execute_close(fd: int, id: string, st: astate): astate = (
  close_resources(st);
  emit(fd, jobj2("id", JStr(id), "type", JStr("closed")));
  AState(MCNone(), MLNone(), SubNil())
)

datatype cont_or_stop = Continue | Stop

fun execute_command(fd: int, cmd: command, st: astate): (astate, cont_or_stop) =
  case+ cmd of
  | CmdHello(id) => (execute_hello(fd, id, st), Continue())
  | CmdCall(id, opk, path, args) => (execute_call(fd, id, opk, path, args, st), Continue())
  | CmdSetAuth(id, tok) => (execute_set_auth(fd, id, tok, st), Continue())
  | CmdSubscribe(id, sub, path, args) => (execute_subscribe(fd, id, sub, path, args, st), Continue())
  | CmdUnsubscribe(id, sub) => (execute_unsubscribe(fd, id, sub, st), Continue())
  | CmdDebugDisconnect(id) => (execute_debug_disconnect(fd, id, st), Continue())
  | CmdClose(id) => (execute_close(fd, id, st), Stop())

fun handle_line(fd: int, line: string, st: astate): (astate, cont_or_stop) =
  case+ parse_json(line) of
  | JONone() => (emit_error(fd, SONone(), SONone(), "ProtocolError", "adapter command was not valid JSON"); (st, Continue()))
  | JOSome(j) => (
      case+ parse_command(j) of
      | POParsed(cmd) => execute_command(fd, cmd, st)
      | POInvalid(mid, msg) => (emit_error(fd, mid, SONone(), "ProtocolError", msg); (st, Continue()))
    )

fun handle_control(inFd: int, outFd: int, st: astate): (astate, cont_or_stop) = let
  val (kind, text) = read_line(inFd)
in
  if kind = LINE_OK then handle_line(outFd, text, st)
  else if kind = LINE_EOF then (close_resources(st); (st, Stop()))
  else (emit_error(outFd, SONone(), SONone(), "TransportError", text); (st, Continue()))
end

fun handle_live(outFd: int, st: astate): astate = let
  val AState(mc, ml, subs) = st
in
  case+ ml of
  | MLNone() => st
  | MLSome(conn, lst) => (
      case+ live_poll(conn, lst) of
      | LiveTransition(lst2, changes) => (deliver_changes(outFd, subs, changes); AState(mc, MLSome(conn, lst2), subs))
      | LivePing() => st
      | LiveIgnored() => st
      | LiveWouldBlock() => st
      | LiveProtocolError(msg) => (
          broadcast_disconnect(outFd, subs, "ProtocolError", msg);
          live_close(conn);
          AState(mc, MLNone(), subs)
        )
      | LivePeerClosed() => (
          broadcast_disconnect(outFd, subs, "TransportError", "Live connection closed by the server");
          live_close(conn);
          AState(mc, MLNone(), subs)
        )
    )
end

and deliver_changes(outFd: int, subs: sublist, changes: changelist): void =
  case+ changes of
  | CLNil() => ()
  | CLCons(chg, rest) => (deliver_one_change(outFd, subs, chg); deliver_changes(outFd, subs, rest))

and deliver_one_change(outFd: int, subs: sublist, chg: live_change): void =
  case+ chg of
  | LiveValue(qid, v, logs) => (
      case+ sub_find_by_qid(subs, qid) of
      | SOSome(sub) => let
          val body = JObj(JFLCons("type", JStr("subscription"),
            JFLCons("subscriptionId", JStr(sub),
            JFLCons("value", v,
            JFLCons("logs", strlist_to_jarr2(logs), JFLNil())))))
        in
          emit(outFd, body)
        end
      | SONone() => ()
    )
  | LiveQueryError(qid, e, logs) => (
      case+ sub_find_by_qid(subs, qid) of
      | SOSome(sub) => emit_convex_error(outFd, SONone(), SOSome(sub), e)
      | SONone() => ()
    )

and broadcast_disconnect(outFd: int, subs: sublist, name: string, message: string): void =
  case+ subs of
  | SubNil() => ()
  | SubCons(sub, _, rest) => (emit_error(outFd, SONone(), SOSome(sub), name, message); broadcast_disconnect(outFd, rest, name, message))

(* ---- reactor loop ---- *)

fun reactor_loop(inFd: int, outFd: int, st0: astate): void = let
  val AState(_, ml, _) = st0
  val liveFd = (case+ ml of MLSome(conn, _) => live_fd(conn) | MLNone() => ~1)
  val pr = poll_control(inFd, liveFd, 200)
in
  if pr = POLL_NONE then reactor_loop(inFd, outFd, st0)
  else if pr = POLL_CONTROL then let
    val (st1, cont) = handle_control(inFd, outFd, st0)
  in
    case+ cont of Continue() => reactor_loop(inFd, outFd, st1) | Stop() => ()
  end
  else if pr = POLL_LIVE then let
    val st1 = handle_live(outFd, st0)
  in
    reactor_loop(inFd, outFd, st1)
  end
  else let  (* POLL_BOTH *)
    val (st1, cont) = handle_control(inFd, outFd, st0)
  in
    case+ cont of
    | Continue() => let val st2 = handle_live(outFd, st1) in reactor_loop(inFd, outFd, st2) end
    | Stop() => ()
  end
end

fun run(inFd: int, outFd: int): void = reactor_loop(inFd, outFd, AState(MCNone(), MLNone(), SubNil()))

implement main0() = let
  var present: int
  val listenAddr = c_getenv_or("ADAPTER_LISTEN", present)
in
  if present = 0 then run(0, 1)
  else let
    val colonPos = c_find_colon(listenAddr)
  in
    if colonPos < 0 then println!("adapter: ADAPTER_LISTEN must be host:port")
    else let
      val hostPart = c_sub(listenAddr, 0, colonPos)
      val portText = c_tail(listenAddr, colonPos + 1)
      val (lstatus, lfd, lerr) = tcp_listen(hostPart, c_str_to_int(portText))
    in
      if lstatus <> TLS_OK then println!("adapter: listen failed: ", lerr)
      else let
        val (astatus, afd, aerr) = tcp_accept(lfd)
      in
        if astatus <> TLS_OK then println!("adapter: accept failed: ", aerr)
        else run(afd, afd)
      end
    end
  end
end
