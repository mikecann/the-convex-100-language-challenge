(*
** adapter_logic: the pure half of the NDJSON adapter protocol -- command
** parsing and exact-shape validation, and event JSON shaping. Split out
** from adapter.dats (which owns the reactor loop and every side effect)
** purely so client/tests/conformance/adapter_test.dats can exercise it
** directly.
*)

staload "./convex_json.sats"
staload "./convex.sats"

datatype call_op = OpQuery | OpMutation | OpAction

datatype command =
  | CmdHello of string
  | CmdCall of (string, call_op, string, json)
  | CmdSetAuth of (string, string)
  | CmdSubscribe of (string, string, string, json)
  | CmdUnsubscribe of (string, string)
  | CmdClose of string
  | CmdDebugDisconnect of string

datatype parse_outcome = POParsed of command | POInvalid of (str_opt, string)

fun parse_command(j: json): parse_outcome

(* id, subscriptionId, name, message, data, logs -> the event JSON *)
fun error_event(mid: str_opt, msub: str_opt, name: string, message: string,
    data: json, logs: strlist): json
