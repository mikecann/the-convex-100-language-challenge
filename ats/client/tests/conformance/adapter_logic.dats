#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex.sats"
staload "./adapter_logic.sats"

%{^
#include <string.h>
static int c_str_eq2(const char *a, const char *b) { return strcmp(a, b) == 0; }
static int c_strlen2(const char *s) { return (int) strlen(s); }
%}
extern fun c_str_eq2(a: string, b: string): bool = "mac#c_str_eq2"
extern fun c_strlen2(s: string): int = "mac#c_strlen2"

fun valid_id(so: str_opt): bool =
  case+ so of
  | SOSome(s) => let val n = c_strlen2(s) in n >= 1 andalso n <= 128 end
  | SONone() => false

fun field(fields: json, key: string): json_opt = json_lookup(key, fields)

fun str_field(fields: json, key: string): str_opt =
  case+ field(fields, key) of
  | JOSome(v) => json_string_val(v)
  | JONone() => SONone()

fun call_op_of(s: string): call_op =
  if c_str_eq2(s, "query") then OpQuery
  else if c_str_eq2(s, "mutation") then OpMutation
  else OpAction

fun is_object(j: json): bool = case+ j of JObj(_) => true | _ => false

(* One shared "call-shaped" command (query/mutation/action/subscribe all
   need a path >= 3 chars and an object args field), parsed once and
   dispatched by the caller. *)
datatype path_args_opt = PANone | PASome of (string, json)

fun parse_path_args(j: json): path_args_opt =
  case+ str_field(j, "path") of
  | SONone() => PANone()
  | SOSome(path) =>
      if c_strlen2(path) < 3 then PANone()
      else (
        case+ field(j, "args") of
        | JOSome(argsv) => (if is_object(argsv) then PASome(path, argsv) else PANone())
        | JONone() => PANone()
      )

fun parse_call(id: string, mid: str_opt, j: json, opName: string): parse_outcome =
  case+ parse_path_args(j) of
  | PANone() => POInvalid(mid, "invalid adapter command")
  | PASome(path, argsv) => POParsed(CmdCall(id, call_op_of(opName), path, argsv))

fun parse_subscribe(id: string, mid: str_opt, j: json): parse_outcome = let
  val msub = str_field(j, "subscriptionId")
in
  if not(valid_id(msub)) then POInvalid(mid, "invalid adapter command")
  else (
    case+ parse_path_args(j) of
    | PANone() => POInvalid(mid, "invalid adapter command")
    | PASome(path, argsv) => let
        val SOSome(sub) = msub
      in
        POParsed(CmdSubscribe(id, sub, path, argsv))
      end
  )
end

fun parse_unsubscribe(id: string, mid: str_opt, j: json): parse_outcome = let
  val msub = str_field(j, "subscriptionId")
in
  if valid_id(msub) then let val SOSome(sub) = msub in POParsed(CmdUnsubscribe(id, sub)) end
  else POInvalid(mid, "invalid adapter command")
end

fun parse_set_auth(id: string, mid: str_opt, j: json): parse_outcome =
  case+ str_field(j, "token") of
  | SOSome(tok) => POParsed(CmdSetAuth(id, tok))
  | SONone() => POInvalid(mid, "invalid adapter command")

fun dispatch_op(id: string, mid: str_opt, j: json, opName: string): parse_outcome =
  if c_str_eq2(opName, "hello") then POParsed(CmdHello(id))
  else if c_str_eq2(opName, "query") then parse_call(id, mid, j, opName)
  else if c_str_eq2(opName, "mutation") then parse_call(id, mid, j, opName)
  else if c_str_eq2(opName, "action") then parse_call(id, mid, j, opName)
  else if c_str_eq2(opName, "setAuth") then parse_set_auth(id, mid, j)
  else if c_str_eq2(opName, "subscribe") then parse_subscribe(id, mid, j)
  else if c_str_eq2(opName, "unsubscribe") then parse_unsubscribe(id, mid, j)
  else if c_str_eq2(opName, "close") then POParsed(CmdClose(id))
  else if c_str_eq2(opName, "debugDisconnect") then POParsed(CmdDebugDisconnect(id))
  else POInvalid(mid, "invalid adapter command")

fun parse_object_command(j: json): parse_outcome = let
  val mid = str_field(j, "id")
in
  if not(valid_id(mid)) then POInvalid(SONone(), "adapter command omitted a valid id")
  else let
    val SOSome(id) = mid
  in
    case+ str_field(j, "op") of
    | SONone() => POInvalid(mid, "adapter command omitted a string op")
    | SOSome(opName) => dispatch_op(id, mid, j, opName)
  end
end

implement parse_command(j) =
  if is_object(j) then parse_object_command(j)
  else POInvalid(SONone(), "adapter command was not a JSON object")

fun strlist_to_jarr(xs: strlist): json =
  case+ xs of
  | SLNil() => JArr(JLNil())
  | SLCons(s, rest) => (
      case+ strlist_to_jarr(rest) of
      | JArr(tail) => JArr(JLCons(JStr(s), tail))
      | other => other
    )

implement error_event(mid, msub, name, message, data, logs) = let
  val errFields0 = JFLCons("name", JStr(name), JFLCons("message", JStr(message), JFLNil()))
  val errFields = (case+ data of JNull() => errFields0 | _ => JFLCons("data", data, errFields0))
  val baseFields = JFLCons("error", JObj(errFields), JFLCons("logs", strlist_to_jarr(logs), JFLNil()))
in
  case+ msub of
  | SOSome(sub) => JObj(JFLCons("type", JStr("subscription"), JFLCons("subscriptionId", JStr(sub), baseFields)))
  | SONone() => (
      case+ mid of
      | SOSome(id) => JObj(JFLCons("type", JStr("error"), JFLCons("id", JStr(id), baseFields)))
      | SONone() => JObj(JFLCons("type", JStr("error"), baseFields))
    )
end
