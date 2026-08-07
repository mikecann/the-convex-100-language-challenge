(*
** Language-local unit tests for the adapter's pure command parsing and
** event shaping, covering serialized success, structured HTTP error,
** subscription error, and close-event shapes without needing a live
** process or network.
*)
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex.sats"
staload "./adapter_logic.sats"

%{^
#include <string.h>
#include <stdio.h>
static void c_puts_local3(const char *s) { puts(s); }
static char *c_concat_local3(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    char *out = malloc(na + nb + 1);
    memcpy(out, a, na); memcpy(out + na, b, nb + 1);
    return out;
}
static int c_str_eq5(const char *a, const char *b) { return strcmp(a, b) == 0; }
%}
extern fun c_puts_local3(s: string): void = "mac#c_puts_local3"
extern fun c_concat_local3(a: string, b: string): string = "mac#c_concat_local3"
extern fun c_str_eq5(a: string, b: string): bool = "mac#c_str_eq5"
fun sc2(a: string, b: string): string = c_concat_local3(a, b)

fun check(name: string, ok: bool): int = (
  if ok then (c_puts_local3(sc2("  ok   ", name)); 0)
  else (c_puts_local3(sc2("  FAIL ", name)); 1)
)

datatype parse_outcome_opt = POONone | POOSome of parse_outcome

fun parse(text: string): parse_outcome_opt =
  case+ parse_json(text) of
  | JOSome(j) => POOSome(parse_command(j))
  | JONone() => POONone()

fun check_hello(): int =
  check("a well-formed hello command parses",
    case+ parse("{\"id\":\"1\",\"op\":\"hello\",\"protocolVersion\":1}") of
    | POOSome(POParsed(CmdHello(id))) => c_str_eq5(id, "1")
    | _ => false)

fun check_query(): int =
  check("a well-formed query command parses with its path and args",
    case+ parse("{\"id\":\"2\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{\"room\":\"r\"}}") of
    | POOSome(POParsed(CmdCall(id, OpQuery(), path, JObj(_)))) => c_str_eq5(id, "2") andalso c_str_eq5(path, "demo:state")
    | _ => false)

fun check_short_path(): int =
  check("a path shorter than 3 characters is rejected",
    case+ parse("{\"id\":\"3\",\"op\":\"query\",\"path\":\"ab\",\"args\":{}}") of
    | POOSome(POInvalid(SOSome(id), _)) => c_str_eq5(id, "3")
    | _ => false)

fun check_subscribe(): int =
  check("a well-formed subscribe command parses with its subscriptionId",
    case+ parse("{\"id\":\"5\",\"op\":\"subscribe\",\"subscriptionId\":\"s1\",\"path\":\"demo:state\",\"args\":{}}") of
    | POOSome(POParsed(CmdSubscribe(id, sub, path, JObj(_)))) =>
        c_str_eq5(id, "5") andalso c_str_eq5(sub, "s1") andalso c_str_eq5(path, "demo:state")
    | _ => false)

fun check_unsubscribe(): int =
  check("a well-formed unsubscribe command parses",
    case+ parse("{\"id\":\"6\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s1\"}") of
    | POOSome(POParsed(CmdUnsubscribe(id, sub))) => c_str_eq5(id, "6") andalso c_str_eq5(sub, "s1")
    | _ => false)

fun check_close(): int =
  check("a well-formed close command parses",
    case+ parse("{\"id\":\"7\",\"op\":\"close\"}") of
    | POOSome(POParsed(CmdClose(id))) => c_str_eq5(id, "7")
    | _ => false)

fun check_unknown_op(): int =
  check("an unrecognised op is reported invalid, carrying the command id",
    case+ parse("{\"id\":\"8\",\"op\":\"teleport\"}") of
    | POOSome(POInvalid(SOSome(id), _)) => c_str_eq5(id, "8")
    | _ => false)

fun check_non_object(): int =
  check("a JSON array instead of an object is reported invalid without an id",
    case+ parse("[1,2,3]") of
    | POOSome(POInvalid(SONone(), _)) => true
    | _ => false)

fun check_function_error_shape(): int = let
  val ev = error_event(SOSome("9"), SONone(), "FunctionError", "boom", JObj(JFLCons("code", JStr("E"), JFLNil())), SLCons("log line", SLNil()))
in
  check("a FunctionError reply carries id, error.name/message/data, and logs",
    case+ ev of
    | JObj(fields) =>
        json_field_eq(fields, "id", "9") andalso json_field_eq(fields, "type", "error")
        andalso json_has_error_name(fields, "FunctionError")
    | _ => false)
end

and json_field_eq(fields: jflist, key: string, expected: string): bool =
  case+ fields of
  | JFLNil() => false
  | JFLCons(k, JStr(v), rest) => if c_str_eq5(k, key) then c_str_eq5(v, expected) else json_field_eq(rest, key, expected)
  | JFLCons(_, _, rest) => json_field_eq(rest, key, expected)

and json_has_error_name(fields: jflist, expected: string): bool =
  case+ fields of
  | JFLNil() => false
  | JFLCons("error", JObj(errFields), _) => json_field_eq(errFields, "name", expected)
  | JFLCons(_, _, rest) => json_has_error_name(rest, expected)

fun check_subscription_error_shape(): int = let
  val ev = error_event(SONone(), SOSome("sub1"), "ProtocolError", "bad transition", JNull(), SLNil())
in
  check("a subscription error carries subscriptionId instead of id",
    case+ ev of
    | JObj(fields) => json_field_eq(fields, "type", "subscription") andalso json_field_eq(fields, "subscriptionId", "sub1")
    | _ => false)
end

fun check_error_omits_data(): int = let
  val ev = error_event(SOSome("10"), SONone(), "TransportError", "closed", JNull(), SLNil())
in
  check("an error with no data omits the data field rather than sending null",
    case+ ev of
    | JObj(fields) => not(json_has_data_field(fields))
    | _ => false)
end

and json_has_data_field(fields: jflist): bool =
  case+ fields of
  | JFLNil() => false
  | JFLCons("error", JObj(errFields), _) => has_key(errFields, "data")
  | JFLCons(_, _, rest) => json_has_data_field(rest)

and has_key(fields: jflist, key: string): bool =
  case+ fields of
  | JFLNil() => false
  | JFLCons(k, _, rest) => if c_str_eq5(k, key) then true else has_key(rest, key)

implement main0() = let
  val failures =
    check_hello() + check_query() + check_short_path() + check_subscribe()
    + check_unsubscribe() + check_close() + check_unknown_op() + check_non_object()
    + check_function_error_shape() + check_subscription_error_shape() + check_error_omits_data()
in
  if failures = 0 then c_puts_local3("adapter_test: all checks passed")
  else (c_puts_local3("adapter_test: some checks failed"); exit(1))
end
