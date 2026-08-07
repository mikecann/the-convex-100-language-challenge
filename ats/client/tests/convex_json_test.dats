(*
** Language-local unit tests for convex_json: parse/render round-trips and
** the integral-number acceptance rules the canonical example's counter
** decoding depends on.
*)
#include "share/atspre_staload.hats"
staload "./convex_json.sats"

%{^
#include <string.h>
#include <stdio.h>
static void c_puts_local(const char *s) { puts(s); }
static char *c_concat_local(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    char *out = malloc(na + nb + 1);
    memcpy(out, a, na); memcpy(out + na, b, nb + 1);
    return out;
}
%}
extern fun c_puts_local(s: string): void = "mac#c_puts_local"
extern fun c_concat_local(a: string, b: string): string = "mac#c_concat_local"
fun sc2(a: string, b: string): string = c_concat_local(a, b)

fun check(name: string, ok: bool): int = (
  if ok then (c_puts_local(sc2("  ok   ", name)); 0)
  else (c_puts_local(sc2("  FAIL ", name)); 1)
)

fun json_eq(a: json, b: json): bool =
  case+ (a, b) of
  | (JNull(), JNull()) => true
  | (JBool(x), JBool(y)) => x = y
  | (JNum(x), JNum(y)) => x = y
  | (JStr(x), JStr(y)) => c_streq_local(x, y)
  | (JArr(x), JArr(y)) => jlist_eq(x, y)
  | (JObj(x), JObj(y)) => jflist_eq(x, y)
  | (_, _) => false

and jlist_eq(a: jlist, b: jlist): bool =
  case+ (a, b) of
  | (JLNil(), JLNil()) => true
  | (JLCons(x, xs), JLCons(y, ys)) => json_eq(x, y) andalso jlist_eq(xs, ys)
  | (_, _) => false

and jflist_eq(a: jflist, b: jflist): bool =
  case+ (a, b) of
  | (JFLNil(), JFLNil()) => true
  | (JFLCons(k1, v1, xs), JFLCons(k2, v2, ys)) =>
      c_streq_local(k1, k2) andalso json_eq(v1, v2) andalso jflist_eq(xs, ys)
  | (_, _) => false

and c_streq_local(a: string, b: string): bool = $extfcall(bool, "c_str_eq3", a, b)

%{
static int c_str_eq3(const char *a, const char *b) { return strcmp(a, b) == 0; }
%}

fun check_object_roundtrip(): int =
  case+ parse_json("{\"path\":\"counters:get\",\"args\":{\"room\":\"r1\",\"n\":2},\"ok\":true,\"missing\":null}") of
  | JOSome(v) => let val rendered = json_to_string(v) in
      check("object round-trip preserves keys and nested types",
        case+ parse_json(rendered) of JOSome(v2) => json_eq(v, v2) | JONone() => false)
    end
  | JONone() => check("object round-trip preserves keys and nested types", false)

fun check_array_roundtrip(): int =
  case+ parse_json("[1, 2.5, \"three\", false, null, []]") of
  | JOSome(JArr(JLCons(JNum(a), JLCons(JNum(b), JLCons(JStr(c), JLCons(JBool(false), JLCons(JNull(), JLCons(JArr(JLNil()), JLNil())))))))) =>
      check("array of mixed values parses", a = 1.0 andalso b = 2.5 andalso c_streq_local(c, "three"))
  | _ => check("array of mixed values parses", false)

fun check_escapes(): int =
  case+ parse_json("\"line1\\nline2\\ttab\\\"quote\\\"\\\\backslash\"") of
  | JOSome(JStr(s)) => check("backslash, quote, and control escapes decode", c_streq_local(s, "line1\nline2\ttab\"quote\"\\backslash"))
  | _ => check("backslash, quote, and control escapes decode", false)

fun check_trailing_garbage(): int =
  check("trailing bytes after a valid value are rejected",
    case+ parse_json("1 2") of JONone() => true | JOSome(_) => false)

fun check_unterminated_string(): int =
  check("an unterminated string literal is rejected",
    case+ parse_json("\"abc") of JONone() => true | JOSome(_) => false)

fun check_integral_accepts(): int =
  case+ parse_json("1.0") of
  | JOSome(v) => check("an integral-valued JSON number such as 1.0 decodes to 1",
      case+ json_integral_int(v) of IOSome(1) => true | _ => false)
  | JONone() => check("an integral-valued JSON number such as 1.0 decodes to 1", false)

fun check_integral_rejects_fraction(): int =
  case+ parse_json("1.5") of
  | JOSome(v) => check("a fractional JSON number is rejected",
      case+ json_integral_int(v) of IONone() => true | _ => false)
  | JONone() => check("a fractional JSON number is rejected", false)

fun check_integral_rejects_range(): int =
  case+ parse_json("9007199254740993") of
  | JOSome(v) => check("a JSON number outside the safe-integer range is rejected",
      case+ json_integral_int(v) of IONone() => true | _ => false)
  | JONone() => check("a JSON number outside the safe-integer range is rejected", false)

fun check_number_render(): int =
  check("a whole-number value renders without a trailing decimal point",
    c_streq_local(json_to_string(JNum(4.0)), "4"))

fun check_lookup_missing(): int =
  case+ parse_json("{\"a\":1}") of
  | JOSome(v) => check("json_lookup fails on an absent key",
      case+ json_lookup("b", v) of JONone() => true | JOSome(_) => false)
  | JONone() => check("json_lookup fails on an absent key", false)

implement main0() = let
  val failures =
    check_object_roundtrip() + check_array_roundtrip() + check_escapes()
    + check_trailing_garbage() + check_unterminated_string()
    + check_integral_accepts() + check_integral_rejects_fraction()
    + check_integral_rejects_range() + check_number_render() + check_lookup_missing()
in
  if failures = 0 then c_puts_local("convex_json_test: all checks passed")
  else (c_puts_local("convex_json_test: some checks failed"); exit(1))
end
