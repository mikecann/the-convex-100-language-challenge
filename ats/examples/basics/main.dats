(*
** Convex from ATS: the canonical shared counter demonstration.
**
** Walks the same 0 -> 1 journey every language in this project
** demonstrates: an HTTP query for the current count, a Live subscription
** started before any write so the reactive path cannot miss it, an
** idempotent mutation, and the resulting Live update -- proving HTTP and
** Live agree about the same room.
*)
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"

%{^
#include <stdlib.h>
#include <string.h>
static char *c_getenv_impl(const char *name, int *out_present) {
    char *v = getenv(name);
    *out_present = (v != NULL);
    return v != NULL ? v : "";
}
%}
extern fun c_getenv(name: string, out_present: &int? >> int): string = "mac#c_getenv_impl"
extern fun c_concat(a: string, b: string): string = "mac#c_concat"
extern fun c_int_to_string(i: int): string = "mac#c_int_to_string"
fun sc2(a: string, b: string): string = c_concat(a, b)
fun sc3(a: string, b: string, c: string): string = sc2(sc2(a, b), c)

(* println! resolves its printable-argument overload polymorphically, which
   gets ambiguous with this file's own datatypes in scope; every line of
   this example's happy-path transcript is built as one plain string
   instead and printed with a single, unambiguous call. *)
%{^
#include <stdio.h>
static void c_println(const char *s) { puts(s); }
static void c_eprintln(const char *s) { fprintf(stderr, "%s\n", s); }
%}
extern fun c_println(s: string): void = "mac#c_println"
extern fun c_eprintln(s: string): void = "mac#c_eprintln"

fun fail_with(msg: string): void = let
  val () = c_eprintln(sc2("ats example failed: ", msg))
in
  exit(1)
end

fun whole_count(operation: string, j: json): int =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("count", j) of
      | JOSome(cj) => (
          case+ json_integral_int(cj) of
          | IOSome(n) => n
          | IONone() => (fail_with(sc2(operation, " did not contain a whole count")); 0)
        )
      | JONone() => (fail_with(sc2(operation, " did not contain a whole count")); 0)
    )
  | _ => (fail_with(sc2(operation, " was not an object")); 0)

fun mutation_applied(j: json): bool =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("applied", j) of
      | JOSome(JBool(b)) => b
      | _ => false
    )
  | _ => false

fun mutation_state(j: json): json =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("state", j) of
      | JOSome(v) => v
      | JONone() => (fail_with("mutation response omitted state"); JNull())
    )
  | _ => (fail_with("mutation response omitted state"); JNull())

fun error_msg(e: convex_error): string =
  case+ e of
  | FunctionErr(msg, _, _) => msg
  | ProtocolErr(msg) => msg
  | TransportErr(msg) => msg

datatype live_wait_result = LWROk of (json, live_state) | LWRFailed
datatype change_result = CHNone | CHValue of json | CHError of convex_error

fun find_change(changes: changelist, queryId: int): change_result =
  case+ changes of
  | CLNil() => CHNone()
  | CLCons(LiveValue(qid, v, _), rest) => if qid = queryId then CHValue(v) else find_change(rest, queryId)
  | CLCons(LiveQueryError(qid, e, _), rest) => if qid = queryId then CHError(e) else find_change(rest, queryId)

fun await_live_loop(conn: live_conn, st: live_state, queryId: int, label: string, triesLeft: int): live_wait_result =
  if triesLeft <= 0 then (fail_with(sc2(label, " timed out")); LWRFailed())
  else let
    val pr = poll_control(~1, live_fd(conn), 100)
  in
    if pr = POLL_LIVE orelse pr = POLL_BOTH then (
      case+ live_poll(conn, st) of
      | LiveTransition(st1, changes) => (
          case+ find_change(changes, queryId) of
          | CHNone() => await_live_loop(conn, st1, queryId, label, triesLeft - 1)
          | CHValue(v) => LWROk(v, st1)
          | CHError(e) => (fail_with(sc2(label, sc2(" was an error: ", error_msg(e)))); LWRFailed())
        )
      | LivePing() => await_live_loop(conn, st, queryId, label, triesLeft - 1)
      | LiveIgnored() => await_live_loop(conn, st, queryId, label, triesLeft - 1)
      | LiveWouldBlock() => await_live_loop(conn, st, queryId, label, triesLeft - 1)
      | LiveProtocolError(msg) => (fail_with(sc2(label, sc2(": protocol error: ", msg))); LWRFailed())
      | LivePeerClosed() => (fail_with(sc2(label, ": connection closed")); LWRFailed())
    )
    else await_live_loop(conn, st, queryId, label, triesLeft - 1)
  end

fun await_live(conn: live_conn, st: live_state, queryId: int, label: string): (json, live_state) =
  case+ await_live_loop(conn, st, queryId, label, 100) of
  | LWROk(v, st1) => (v, st1)
  | LWRFailed() => (JNull(), st)  (* unreachable: await_live_loop already exited on failure *)

implement main0(argc, argv) = let
  var present: int
  val url = c_getenv("CONVEX_URL", present)
in
  if present = 0 then fail_with("CONVEX_URL is required")
  else (
    case+ new_client(url) of
    | CONone() => fail_with("CONVEX_URL is not a valid Convex deployment URL")
    | COSome(c) => let
        val room = if argc >= 2 then argv[1] else "ats-example"
        val roomArgs = jobj1("room", JStr(room))
      in
        case+ http_query(c, "demo:state", roomArgs) of
        | CallErr(e) => fail_with(sc2("current query failed: ", error_msg(e)))
        | CallOk(qv, _) => let
            val currentCount = whole_count("current query", qv)
            val () = c_println(sc2("current count: ", c_int_to_string(currentCount)))
          in
            case+ live_connect(c) of
            | LiveErr(e) => fail_with(sc2("Live connect failed: ", error_msg(e)))
            | LiveOkConn(conn, st0) => (
                case+ live_add(conn, st0, "demo:state", roomArgs) of
                | AddErr(msg) => (live_close(conn); fail_with(sc2("could not subscribe: ", msg)))
                | AddOk(queryId, st1) => let
                    val (initialV, st2) = await_live(conn, st1, queryId, "initial Live value")
                    val initialCount = whole_count("initial Live value", initialV)
                    val () = if initialCount <> currentCount
                      then fail_with("Live initial value disagreed with HTTP") else ()
                    val () = c_println(sc2("live initial count: ", c_int_to_string(initialCount)))
                    val runId = random_hex(16)
                    val mutArgs = JObj(JFLCons("room", JStr(room),
                      JFLCons("language", JStr("ats"), JFLCons("runId", JStr(runId), JFLNil()))))
                  in
                    case+ http_mutation(c, "demo:increment", mutArgs) of
                    | CallErr(e) => (live_close(conn); fail_with(sc2("mutation failed: ", error_msg(e))))
                    | CallOk(mv, _) => let
                        val applied = mutation_applied(mv)
                        val appliedWord: string = (if applied then "true" else "false")
                        val () = c_println(sc2("mutation applied: ", appliedWord))
                        val mutationCount = whole_count("mutation", mutation_state(mv))
                        val () = if mutationCount <> currentCount + 1
                          then fail_with("mutation count was unexpected") else ()
                        val () = c_println(sc2("mutation count: ", c_int_to_string(mutationCount)))
                        val (updatedV, st3) = await_live(conn, st2, queryId, "updated Live value")
                        val updatedCount = whole_count("updated Live value", updatedV)
                        val () = if updatedCount <> mutationCount
                          then fail_with("Live update was unexpected") else ()
                        val () = c_println(sc2("live updated count: ", c_int_to_string(updatedCount)))
                        val () = c_println(sc3(
                          sc2("verified count: ", c_int_to_string(currentCount)),
                          " -> ", c_int_to_string(updatedCount)))
                        val st4 = live_remove(conn, st3, queryId)
                        val () = live_close(conn)
                      in
                        ()
                      end
                  end
              )
          end
      end
  )
end
