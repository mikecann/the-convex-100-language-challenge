NB. convex_test.ijs -- deployment URL parsing, the integral-number decoding
NB. rule, and the HTTP header/status-line/chunked-body framing helpers, all
NB. exercised as pure functions on hand-built text (no socket needed).

load '/project/client/convex.ijs'

TEST_FAILED=: 0

test_fail=: 3 : 0
  TEST_FAILED=: 1
  echo 'FAIL: ', y
  i. 0
)

main=: 3 : 0
NB. --- URL parsing ---
if. -. convex_open 'https://example.com';'t' do. test_fail 'https URL should open' end.
if. CX_SECURE ~: 1 do. test_fail 'https should set CX_SECURE' end.
if. CX_PORT ~: 443 do. test_fail 'https default port should be 443' end.
if. -. CX_HOST -: 'example.com' do. test_fail 'CX_HOST parsed wrong' end.

if. -. convex_open 'http://example.com:8080';'t' do. test_fail 'http URL with port should open' end.
if. CX_SECURE ~: 0 do. test_fail 'http should clear CX_SECURE' end.
if. CX_PORT ~: 8080 do. test_fail 'explicit port should be parsed' end.
if. -. CX_HOST_HEADER -: 'example.com:8080' do. test_fail 'Host header should include non-default port' end.

if. convex_open 'ftp://example.com';'t' do. test_fail 'non-http(s) scheme should be rejected' end.
if. convex_open 'https://example.com/path';'t' do. test_fail 'a path should be rejected' end.
if. convex_open 'https://user@example.com';'t' do. test_fail 'userinfo should be rejected' end.
if. convex_open 'https://';'t' do. test_fail 'a missing host should be rejected' end.
if. convex_open 'https://example.com:99999';'t' do. test_fail 'an out-of-range port should be rejected' end.

NB. --- convex_integral ---
if. -. convex_integral '0' do. test_fail 'convex_integral 0' end.
if. -. convex_integral '0.0' do. test_fail 'convex_integral 0.0' end.
if. convex_integral '0.5' do. test_fail 'convex_integral 0.5 should reject' end.
if. convex_integral '9007199254740993' do. test_fail 'convex_integral over safe-int should reject' end.
if. -. convex_integral '9007199254740992' do. test_fail 'convex_integral at safe-int boundary should accept' end.
if. -. convex_integral '-5' do. test_fail 'convex_integral negative literal should accept (sign is a caller concern)' end.
if. convex_integral '' do. test_fail 'convex_integral empty string should reject' end.
if. convex_integral 'abc' do. test_fail 'convex_integral non-numeric should reject' end.

NB. --- HTTP status line ---
if. (cx_http_status 'HTTP/1.1 200 OK', CR, LF) ~: 200 do. test_fail 'status line 200' end.
if. (cx_http_status 'HTTP/1.1 404 Not Found', CR, LF) ~: 404 do. test_fail 'status line 404' end.
if. 0 <: cx_http_status 'not a status line' do. test_fail 'malformed status line should be rejected' end.
if. 0 <: cx_http_status 'HTTP/1.1' do. test_fail 'truncated status line should be rejected, not indexed out of bounds' end.

NB. --- headers ---
block=. 'Content-Type: application/json', CR, LF, 'Content-Length: 42', CR, LF
hparsed=. cx_http_headers block
hok=. > 0 { hparsed
headers=. > 1 { hparsed
if. -. hok do. test_fail 'well-formed header block should parse' end.
if. -. headers cx_header_present 'content-length' do. test_fail 'header lookup should be case-insensitive' end.
if. -. (headers cx_header_find 'content-type') -: 'application/json' do. test_fail 'header value extraction' end.
if. headers cx_header_present 'missing-header' do. test_fail 'absent header should not be present' end.

badblock=. 'not-a-header-line', CR, LF
bparsed=. cx_http_headers badblock
if. > 0 { bparsed do. test_fail 'a header line with no colon should be rejected' end.

exit TEST_FAILED
)
main ''
