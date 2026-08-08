#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload UN = "prelude/SATS/unsafe.sats"

%{^
#include <cjson/cJSON.h>
#include <string.h>
#include <math.h>

static char *cj_strdup(const char *s) {
    size_t n = strlen(s);
    char *out = malloc(n + 1);
    memcpy(out, s, n + 1);
    return out;
}

static void cj_parse(const char *text, int *out_ok, void **out_tree) {
    /* require_null_terminated=1 rejects trailing bytes after the value
       (e.g. "1 2"), which the permissive cJSON_Parse would silently
       accept by just stopping at the first complete value. */
    cJSON *root = cJSON_ParseWithLengthOpts(text, strlen(text) + 1, NULL, 1);
    *out_ok = (root != NULL);
    *out_tree = root;
}
static void cj_free(void *tree) { if (tree != NULL) cJSON_Delete((cJSON *) tree); }

/* 0=null 1=false 2=true 3=number 4=string 5=array 6=object */
static int cj_type(void *node) {
    cJSON *n = (cJSON *) node;
    if (cJSON_IsNull(n)) return 0;
    if (cJSON_IsFalse(n)) return 1;
    if (cJSON_IsTrue(n)) return 2;
    if (cJSON_IsNumber(n)) return 3;
    if (cJSON_IsString(n)) return 4;
    if (cJSON_IsArray(n)) return 5;
    if (cJSON_IsObject(n)) return 6;
    return 0;
}
static double cj_num(void *node) { return ((cJSON *) node)->valuedouble; }
static char *cj_str(void *node) { return cj_strdup(((cJSON *) node)->valuestring); }
static int cj_size(void *node) { return cJSON_GetArraySize((cJSON *) node); }
static void *cj_item(void *node, int i) { return cJSON_GetArrayItem((cJSON *) node, i); }
static char *cj_key(void *node, int i) {
    cJSON *item = cJSON_GetArrayItem((cJSON *) node, i);
    return cj_strdup(item->string != NULL ? item->string : "");
}

static int c_double_to_int(double d) { return (int) (long long) d; }
static double c_int_to_double(int i) { return (double) i; }
static char *c_double_to_string(double d) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%.17g", d);
    return cj_strdup(buf);
}
static char *c_int_to_string(int i) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", i);
    return cj_strdup(buf);
}
static char *c_concat(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    char *out = malloc(na + nb + 1);
    memcpy(out, a, na);
    memcpy(out + na, b, nb + 1);
    return out;
}
/* Escapes one JSON string's contents (without surrounding quotes). */
static char *c_json_escape(const char *s) {
    size_t n = strlen(s);
    char *out = malloc(n * 6 + 1);
    size_t oi = 0;
    size_t i;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char) s[i];
        if (c == '"') { out[oi++] = '\\'; out[oi++] = '"'; }
        else if (c == '\\') { out[oi++] = '\\'; out[oi++] = '\\'; }
        else if (c == '\n') { out[oi++] = '\\'; out[oi++] = 'n'; }
        else if (c == '\r') { out[oi++] = '\\'; out[oi++] = 'r'; }
        else if (c == '\t') { out[oi++] = '\\'; out[oi++] = 't'; }
        else if (c < 0x20) { oi += snprintf(out + oi, 7, "\\u%04x", c); }
        else out[oi++] = (char) c;
    }
    out[oi] = '\0';
    return out;
}
%}

extern fun cj_parse(text: string, out_ok: &int? >> int, out_tree: &ptr? >> ptr): void = "mac#cj_parse"
extern fun cj_free(tree: ptr): void = "mac#cj_free"
extern fun cj_type(node: ptr): int = "mac#cj_type"
extern fun cj_num(node: ptr): double = "mac#cj_num"
extern fun cj_str(node: ptr): string = "mac#cj_str"
extern fun cj_size(node: ptr): int = "mac#cj_size"
extern fun cj_item(node: ptr, i: int): ptr = "mac#cj_item"
extern fun cj_key(node: ptr, i: int): string = "mac#cj_key"
extern fun c_double_to_int(d: double): int = "mac#c_double_to_int"
extern fun c_int_to_double(i: int): double = "mac#c_int_to_double"
extern fun c_double_to_string(d: double): string = "mac#c_double_to_string"
extern fun c_int_to_string(i: int): string = "mac#c_int_to_string"
extern fun c_concat(a: string, b: string): string = "mac#c_concat"
extern fun c_json_escape(s: string): string = "mac#c_json_escape"

fun sc2(a: string, b: string): string = c_concat(a, b)
fun sc3(a: string, b: string, c: string): string = c_concat(c_concat(a, b), c)
fun sc4(a: string, b: string, c: string, d: string): string = c_concat(c_concat(a, b), c_concat(c, d))
fun sc5(a: string, b: string, c: string, d: string, e: string): string =
  c_concat(c_concat(c_concat(a, b), c_concat(c, d)), e)

fun cjson_to_json(node: ptr): json = let
  val t = cj_type(node)
in
  if t = 0 then JNull
  else if t = 1 then JBool(false)
  else if t = 2 then JBool(true)
  else if t = 3 then JNum(cj_num(node))
  else if t = 4 then JStr(cj_str(node))
  else if t = 5 then let
    val n = cj_size(node)
    fun loop(i: int): jlist =
      if i >= n then JLNil
      else JLCons(cjson_to_json(cj_item(node, i)), loop(i + 1))
  in
    JArr(loop(0))
  end
  else let  (* t = 6, object *)
    val n = cj_size(node)
    fun loop(i: int): jflist =
      if i >= n then JFLNil
      else JFLCons(cj_key(node, i), cjson_to_json(cj_item(node, i)), loop(i + 1))
  in
    JObj(loop(0))
  end
end

implement parse_json(text) = let
  var ok: int
  var tree: ptr
in
  cj_parse(text, ok, tree);
  if ok = 0 then JONone
  else let
    val j = cjson_to_json(tree)
    val () = cj_free(tree)
  in
    JOSome(j)
  end
end

(* ****** rendering ****** *)

fun render_num(d: double): string = let
  val isnan = (d <> d)
  val isinf = (d > 1.0e308) orelse (d < ~1.0e308)
in
  if isnan orelse isinf then "0"
  else let
    val i = c_double_to_int(d)
  in
    if c_int_to_double(i) = d andalso d >= ~9007199254740991.0 andalso d <= 9007199254740991.0
      then c_int_to_string(i)
      else c_double_to_string(d)
  end
end

fun render_jlist(xs: jlist): string =
  case+ xs of
  | JLNil() => ""
  | JLCons(x, JLNil()) => json_to_string(x)
  | JLCons(x, rest) => sc3(json_to_string(x), ",", render_jlist(rest))

fun render_jflist(xs: jflist): string =
  case+ xs of
  | JFLNil() => ""
  | JFLCons(k, v, JFLNil()) => sc4("\"", c_json_escape(k), "\":", json_to_string(v))
  | JFLCons(k, v, rest) =>
      sc3(sc4("\"", c_json_escape(k), "\":", json_to_string(v)), ",", render_jflist(rest))

implement json_to_string(j) =
  case+ j of
  | JNull() => "null"
  | JBool(b) => (if b then "true" else "false")
  | JNum(d) => render_num(d)
  | JStr(s) => sc3("\"", c_json_escape(s), "\"")
  | JArr(xs) => sc3("[", render_jlist(xs), "]")
  | JObj(xs) => sc3("{", render_jflist(xs), "}")

(* ****** accessors ****** *)

implement json_lookup(key, j) =
  case+ j of
  | JObj(xs) => let
      fun find(xs: jflist): json_opt =
        case+ xs of
        | JFLNil() => JONone
        | JFLCons(k, v, rest) => if k = key then JOSome(v) else find(rest)
    in
      find(xs)
    end
  | _ => JONone

implement json_integral_int(j) =
  case+ j of
  | JNum(d) => let
      val isnan = (d <> d)
      val isinf = (d > 1.0e308) orelse (d < ~1.0e308)
    in
      if isnan orelse isinf then IONone
      else if d < ~9007199254740991.0 orelse d > 9007199254740991.0 then IONone
      else let
        val i = c_double_to_int(d)
      in
        if c_int_to_double(i) = d then IOSome(i) else IONone
      end
    end
  | _ => IONone

implement json_string_val(j) =
  case+ j of
  | JStr(s) => SOSome(s)
  | _ => SONone

implement json_string_list(j) =
  case+ j of
  | JArr(xs) => let
      fun loop(xs: jlist): strlist_opt =
        case+ xs of
        | JLNil() => LOSome(SLNil())
        | JLCons(JStr(s), rest) => (
            case+ loop(rest) of
            | LOSome(tail) => LOSome(SLCons(s, tail))
            | LONone() => LONone()
          )
        | JLCons(_, _) => LONone()
    in
      loop(xs)
    end
  | JNull() => LOSome(SLNil())
  | _ => LONone

(* ****** construction helpers ****** *)

implement jobj1(k1, v1) = JObj(JFLCons(k1, v1, JFLNil()))
implement jobj2(k1, v1, k2, v2) = JObj(JFLCons(k1, v1, JFLCons(k2, v2, JFLNil())))
implement jobj3(k1, v1, k2, v2, k3, v3) =
  JObj(JFLCons(k1, v1, JFLCons(k2, v2, JFLCons(k3, v3, JFLNil()))))
implement jobj4(k1, v1, k2, v2, k3, v3, k4, v4) =
  JObj(JFLCons(k1, v1, JFLCons(k2, v2, JFLCons(k3, v3, JFLCons(k4, v4, JFLNil())))))
implement jobj5(k1, v1, k2, v2, k3, v3, k4, v4, k5, v5) =
  JObj(JFLCons(k1, v1, JFLCons(k2, v2, JFLCons(k3, v3, JFLCons(k4, v4, JFLCons(k5, v5, JFLNil()))))))
implement jarr1(v1) = JArr(JLCons(v1, JLNil()))
