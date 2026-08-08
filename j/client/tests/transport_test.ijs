NB. transport_test.ijs -- the byte/number primitives and small crypto
NB. helpers that do not need a live socket: big/little-endian packing,
NB. bytewise XOR, base64, SHA-1 against the standard test vector, and a
NB. sanity check that the monotonic clock actually advances.

load '/project/client/transport.ijs'

TEST_FAILED=: 0

test_fail=: 3 : 0
  TEST_FAILED=: 1
  echo 'FAIL: ', y
  i. 0
)

hex=: 3 : 0
  ,'0123456789abcdef' {~ (16 16) #: y
)

main=: 3 : 0
if. -. (4 tx_be 16909060) -: 1 2 3 4 do. test_fail 'tx_be big-endian encode' end.
if. (tx_unbe 4 tx_be 16909060) ~: 16909060 do. test_fail 'tx_be/tx_unbe round trip' end.
if. -. (8 tx_le 16909060) -: 4 3 2 1 0 0 0 0 do. test_fail 'tx_le little-endian encode' end.
if. (tx_unle 8 tx_le 16909060) ~: 16909060 do. test_fail 'tx_le/tx_unle round trip' end.

if. (255 tx_xor 15) ~: 240 do. test_fail 'tx_xor single byte' end.
if. -. (255 0 170 5 tx_xor 15 255 85 5) -: 240 255 255 0 do. test_fail 'tx_xor byte list' end.

if. -. (tx_base64_encode 8 # 0) -: 'AAAAAAAAAAA=' do. test_fail 'base64 encode 8 zero bytes' end.
if. -. (tx_base64_encode a. i. 'Man') -: 'TWFu' do. test_fail 'base64 encode "Man"' end.
if. -. (tx_base64_encode a. i. 'Ma') -: 'TWE=' do. test_fail 'base64 encode "Ma"' end.
if. -. (tx_base64_encode a. i. 'M') -: 'TQ==' do. test_fail 'base64 encode "M"' end.
if. -. (tx_base64_decode 'TWFu') -: a. i. 'Man' do. test_fail 'base64 decode "TWFu"' end.
if. -. (tx_base64_decode tx_base64_encode 8 # 0) -: 8 # 0 do. test_fail 'base64 round trip' end.

if. -. (hex tx_sha1 a. i. 'abc') -: 'a9993e364706816aba3e25717850c26c9cd0d89d' do.
  test_fail 'sha1("abc") mismatch: ', hex tx_sha1 a. i. 'abc'
end.

if. 16 ~: # tx_random_bytes 16 do. test_fail 'tx_random_bytes length' end.

u=. tx_uuid ''
if. 36 ~: # u do. test_fail 'tx_uuid length' end.
if. '-' ~: 8 { u do. test_fail 'tx_uuid dash at position 8' end.
if. '4' ~: 14 { u do. test_fail 'tx_uuid version nibble should be 4' end.

t0=. tx_now_ms ''
t1=. tx_now_ms ''
if. t1 < t0 do. test_fail 'tx_now_ms should be monotonic non-decreasing' end.

exit TEST_FAILED
)
main ''
