NB. websocket_test.ijs -- RFC 6455 framing: masking, fragment reassembly, a
NB. control frame arriving mid-fragmentation, and a multi-byte UTF-8
NB. character deliberately split across the fragment boundary (the same
NB. fixture idea icon/ uses for its own frame-boundary test). None of this
NB. needs a socket: ws_fill only calls tx_recv when its buffer runs short,
NB. so pre-loading the whole scripted byte sequence into the buffer first
NB. drives the real frame parser deterministically.

load '/project/client/websocket.ijs'

TEST_FAILED=: 0

test_fail=: 3 : 0
  TEST_FAILED=: 1
  echo 'FAIL: ', y
  i. 0
)

DUMMY_CONN=: (<'plain'),(<_1) NB. never touched: every buffer below is preloaded

NB. ---------------------------------------------------------------------------
NB. Encode: FIN/opcode/mask bits, and the mask actually changes the bytes.
NB. ---------------------------------------------------------------------------

main=: 3 : 0
payload=. a. i. 'hello world'
frame=. ws_encode_text payload
if. (0 { frame) ~: 129 do. test_fail 'text frame byte0 should be 0x81 (FIN+TEXT)' end.
if. (1 { frame) ~: 139 do. test_fail 'text frame byte1 should be 0x8B (MASK+len 11)' end.
mask=. 4 {. 2 }. frame
masked=. 11 {. 6 }. frame
unmasked=. masked tx_xor (11 $ mask)
if. -. unmasked -: payload do. test_fail 'unmasking the encoded frame did not recover the payload' end.
if. (payload -: masked) *. (0 < # payload) do. test_fail 'masked payload should differ from the cleartext payload' end.

closeframe=. ws_encode_close 1000
if. (# closeframe) ~: 8 do. test_fail 'close frame should be 6-byte header + 2-byte code' end.

NB. ---------------------------------------------------------------------------
NB. Handshake accept-key: the exact worked example from RFC 6455 section 1.3.
NB. ---------------------------------------------------------------------------

rfckey=. 'dGhlIHNhbXBsZSBub25jZQ=='
rfcexpect=. 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
rfcaccept=. tx_base64_encode tx_sha1 a. i. rfckey , WS_GUID
if. -. rfcaccept -: rfcexpect do.
  test_fail 'RFC 6455 worked-example accept key mismatch: got ', rfcaccept
end.

NB. ---------------------------------------------------------------------------
NB. Fragment reassembly with a PING interleaved mid-message, and a 4-byte
NB. UTF-8 character (the U+1F600 emoji) split across the fragment boundary:
NB. byte 0-1 end fragment 1, byte 2-3 start the continuation fragment.
NB. ---------------------------------------------------------------------------

emoji=. 240 159 152 128  NB. UTF-8 for U+1F600
part1=. (a. i. 'hi ') , 2 {. emoji
part2=. (2 }. emoji) , (a. i. ' bye')

NB. Frame 1: TEXT, FIN=0 (more fragments follow), so no 128 on the opcode
NB. byte; the length byte also carries no mask bit, since RFC 6455 servers
NB. never mask their frames and ws_read_frame correctly refuses one that
NB. claims to.
f1=. (, WS_OP_TEXT) , (, # part1) , part1
NB. Frame 2: PING control frame, FIN=1, unrelated payload
pingpayload=. a. i. 'ping-mid-message'
f2=. (, 128 + WS_OP_PING) , (, # pingpayload) , pingpayload
NB. Frame 3: CONTINUATION, FIN=1 (message complete)
f3=. (, 128 + WS_OP_CONT) , (, # part2) , part2

NB. The server never masks (RFC 6455 forbids it), so these frames are built
NB. directly with the mask bit clear -- exactly what ws_read_frame expects
NB. to receive from a real deployment.
scripted=. f1 , f2 , f3

buffer=. scripted
'rstatus buffer rfin ropcode rpayload'=. ws_read_frame (<DUMMY_CONN),(<buffer),(<((tx_now_ms '')+1000))
if. rstatus ~: WS_IO_OK do. test_fail 'frame 1 (fragment start) failed to decode' end.
if. rfin do. test_fail 'frame 1 should have FIN=0' end.
if. ropcode ~: WS_OP_TEXT do. test_fail 'frame 1 opcode should be TEXT' end.
if. -. rpayload -: part1 do. test_fail 'frame 1 payload mismatch' end.
assembled=. rpayload

'rstatus buffer rfin ropcode rpayload'=. ws_read_frame (<DUMMY_CONN),(<buffer),(<((tx_now_ms '')+1000))
if. rstatus ~: WS_IO_OK do. test_fail 'frame 2 (mid-message PING) failed to decode' end.
if. -. rfin do. test_fail 'a control frame must have FIN=1' end.
if. ropcode ~: WS_OP_PING do. test_fail 'frame 2 opcode should be PING' end.
if. -. rpayload -: pingpayload do. test_fail 'PING payload mismatch' end.
NB. A control frame does not touch the in-progress fragment assembly.

'rstatus buffer rfin ropcode rpayload'=. ws_read_frame (<DUMMY_CONN),(<buffer),(<((tx_now_ms '')+1000))
if. rstatus ~: WS_IO_OK do. test_fail 'frame 3 (continuation) failed to decode' end.
if. -. rfin do. test_fail 'frame 3 should have FIN=1 (message complete)' end.
if. ropcode ~: WS_OP_CONT do. test_fail 'frame 3 opcode should be CONTINUATION' end.
if. -. rpayload -: part2 do. test_fail 'frame 3 payload mismatch' end.
assembled=. assembled , rpayload

if. -. assembled -: (a. i. 'hi '),emoji,(a. i. ' bye') do.
  test_fail 'reassembled message does not equal the original bytes'
end.
if. -. ws_utf8_valid assembled do.
  test_fail 'reassembled message (with the rejoined 4-byte character) should be valid UTF-8'
end.
if. 0 = # buffer do. i. 0 else. test_fail 'buffer should be fully consumed after 3 frames' end.

NB. ---------------------------------------------------------------------------
NB. UTF-8 validation edge cases
NB. ---------------------------------------------------------------------------

if. -. ws_utf8_valid a. i. 'plain ascii' do. test_fail 'plain ASCII should validate' end.
if. -. ws_utf8_valid emoji do. test_fail 'a single un-split 4-byte character should validate' end.
if. ws_utf8_valid , 128 do. test_fail 'a lone continuation byte should not validate' end.
if. ws_utf8_valid 192 128 do. test_fail 'an overlong NUL encoding should not validate' end.
if. ws_utf8_valid 237 160 128 do. test_fail 'an encoded UTF-16 surrogate half should not validate' end.
if. -. ws_utf8_valid '' do. test_fail 'an empty message should validate (vacuously)' end.

exit TEST_FAILED
)
main ''
