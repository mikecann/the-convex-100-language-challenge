(*
** Language-local unit tests for convex.dats's pure, network-free logic:
** deployment URL validation and normalisation.
*)
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"

%{^
#include <string.h>
#include <stdio.h>
static void c_puts_local2(const char *s) { puts(s); }
static char *c_concat_local2(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    char *out = malloc(na + nb + 1);
    memcpy(out, a, na); memcpy(out + na, b, nb + 1);
    return out;
}
static int c_str_eq4(const char *a, const char *b) { return strcmp(a, b) == 0; }
%}
extern fun c_puts_local2(s: string): void = "mac#c_puts_local2"
extern fun c_concat_local2(a: string, b: string): string = "mac#c_concat_local2"
extern fun c_str_eq4(a: string, b: string): bool = "mac#c_str_eq4"
fun sc2(a: string, b: string): string = c_concat_local2(a, b)

fun check(name: string, ok: bool): int = (
  if ok then (c_puts_local2(sc2("  ok   ", name)); 0)
  else (c_puts_local2(sc2("  FAIL ", name)); 1)
)

fun check_accepts_https(): int =
  check("an https:// deployment URL is accepted",
    case+ new_client("https://usable-reindeer-44.convex.cloud") of COSome(_) => true | CONone() => false)

fun check_accepts_http(): int =
  check("an http:// deployment URL (self-hosted backend) is accepted",
    case+ new_client("http://backend:3210") of COSome(_) => true | CONone() => false)

fun check_trims_trailing_slash(): int =
  check("a trailing slash is trimmed from the deployment URL",
    case+ new_client("https://example.convex.cloud/") of
    | COSome(Client(url, _)) => c_str_eq4(url, "https://example.convex.cloud")
    | CONone() => false)

fun check_rejects_missing_scheme(): int =
  check("a deployment URL without http(s):// is rejected",
    case+ new_client("example.convex.cloud") of CONone() => true | COSome(_) => false)

fun check_rejects_empty_host(): int =
  check("a scheme with no host is rejected",
    case+ new_client("https://") of CONone() => true | COSome(_) => false)

fun check_rejects_empty_url(): int =
  check("an empty deployment URL is rejected",
    case+ new_client("") of CONone() => true | COSome(_) => false)

fun check_set_clear_auth(): int =
  case+ new_client("https://example.convex.cloud") of
  | CONone() => check("set_auth then clear_auth returns to the unauthenticated client", false)
  | COSome(c0) => let
      val c1 = set_auth("a-token", c0)
      val c2 = clear_auth(c1)
      val Client(_, auth2) = c2
    in
      check("set_auth then clear_auth returns to the unauthenticated client",
        case+ auth2 of SONone() => true | SOSome(_) => false)
    end

implement main0() = let
  val failures =
    check_accepts_https() + check_accepts_http() + check_trims_trailing_slash()
    + check_rejects_missing_scheme() + check_rejects_empty_host() + check_rejects_empty_url()
    + check_set_clear_auth()
in
  if failures = 0 then c_puts_local2("client_test: all checks passed")
  else (c_puts_local2("client_test: some checks failed"); exit(1))
end
