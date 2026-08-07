(*
** convex_json: the JSON value type and codec.
**
** Parsing text into a tree is delegated to cJSON (Ubuntu's own
** `libcjson-dev`, no signing or licensing wrinkle at all) -- the same
** "normal JSON library" role AGENTS.md expects a native client to reach
** for, since ATS ships no JSON support of its own. cJSON's tree is walked
** exactly once, at the FFI boundary in convex_json.dats, into `json`
** below: a genuine ATS algebraic datatype. Every predicate that actually
** interprets a Convex value -- looking up a field, deciding whether a
** number is a whole count, matching a `status` tag -- operates on that
** ATS type via ATS pattern matching, which is exhaustiveness-checked at
** compile time, not on the C tree.
**
** Rendering back to text is NOT round-tripped through cJSON; it is a
** direct ATS recursive function, because it never needs to fail and
** cJSON's tree would just be a detour.
**
** Arrays and objects use hand-rolled list datatypes (jlist/jflist) rather
** than a prelude list type, so this module has no hidden staload
** dependency on which exact list flavour and constructor names a given
** ATS2 distribution ships.
*)

datatype json =
  | JNull
  | JBool of bool
  | JNum of double
  | JStr of string
  | JArr of jlist
  | JObj of jflist

and jlist =
  | JLNil
  | JLCons of (json, jlist)

and jflist =
  | JFLNil
  | JFLCons of (string, json, jflist)

datatype json_opt = JONone | JOSome of json
datatype int_opt = IONone | IOSome of int
datatype str_opt = SONone | SOSome of string
datatype strlist_opt = LONone | LOSome of strlist

and strlist =
  | SLNil
  | SLCons of (string, strlist)

fun parse_json(text: string): json_opt

fun json_to_string(j: json): string

fun json_lookup(key: string, j: json): json_opt

(*
** A Convex JSON number is "integral" when it has no fractional part and
** lies within the safe-integer range Convex (and JavaScript) treat as
** exact: +/- 2^53 - 1. Fractional, quoted, non-finite, and out-of-range
** values all return None rather than a silently truncated int.
*)
fun json_integral_int(j: json): int_opt

fun json_string_val(j: json): str_opt

fun json_string_list(j: json): strlist_opt

(* Small helpers convex.dats needs for building request/message JSON
   without repeating list-construction boilerplate everywhere. *)
fun jobj1(k1: string, v1: json): json
fun jobj2(k1: string, v1: json, k2: string, v2: json): json
fun jobj3(k1: string, v1: json, k2: string, v2: json, k3: string, v3: json): json
fun jobj4(k1: string, v1: json, k2: string, v2: json, k3: string, v3: json, k4: string, v4: json): json
fun jobj5(k1: string, v1: json, k2: string, v2: json, k3: string, v3: json, k4: string, v4: json, k5: string, v5: json): json
fun jarr1(v1: json): json
