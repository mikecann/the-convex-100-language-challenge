module WebSocketTest

// Language-local unit coverage for Convex.WebSocket's pure framing and
// handshake-key logic. Run by the `test` Docker stage; not part of the
// public client or the conformance adapter. The handshake itself, and
// frame I/O over a real socket, need a real peer and are exercised instead
// by `./run verify`/`verify-hosted` once Convex.Live exists.
//
// Every function this test reaches is exported from Convex.WebSocket
// specifically to make it reachable here (opcodeByte, byteToOpcode,
// lengthBytes, maskPayload, isValidUtf8, computeAcceptKey are otherwise
// internal to the frame encode/decode and handshake logic).

import StdEnv
import StdMaybe
import Convex.WebSocket

Start :: *World -> *World
Start w
	| not checkOpcodeRoundtrip = abort "opcodeByte/byteToOpcode did not round-trip every WsOpcode"
	| not checkUnknownOpcodeRejected = abort "byteToOpcode accepted an opcode RFC 6455 does not define"
	| not checkLengthBytesShortForm = abort "lengthBytes: a payload <= 125 bytes should use the single-byte length form"
	| not checkLengthBytesExtended16 = abort "lengthBytes: a payload requiring the 16-bit extended length form was wrong"
	| not checkLengthBytesExtended64 = abort "lengthBytes: a payload requiring the 64-bit extended length form was wrong"
	| not checkMaskIsInvolution = abort "maskPayload: XOR-masking the same payload with the same mask twice should return the original bytes"
	| not checkMaskChangesBytes = abort "maskPayload: masking should actually change every byte of a non-empty payload against a non-zero mask"
	| not checkValidUtf8Accepted = abort "isValidUtf8: well-formed ASCII and multi-byte UTF-8 were rejected"
	| not checkInvalidUtf8Rejected = abort "isValidUtf8: truncated and structurally malformed byte sequences were accepted"
	| not checkAcceptKeyMatchesRfcExample = abort "computeAcceptKey: RFC 6455 section 1.3's own worked example did not match"
	= w

checkOpcodeRoundtrip :: Bool
checkOpcodeRoundtrip = and [roundtrips op \\ op <- [WsContinuation, WsText, WsBinary, WsClose, WsPing, WsPong]]
where
	roundtrips op = byteToOpcode (opcodeByte op) === Just op

	(===) (Just a) (Just b) = sameOpcode a b
	(===) Nothing Nothing = True
	(===) _ _ = False

	sameOpcode WsContinuation WsContinuation = True
	sameOpcode WsText WsText = True
	sameOpcode WsBinary WsBinary = True
	sameOpcode WsClose WsClose = True
	sameOpcode WsPing WsPing = True
	sameOpcode WsPong WsPong = True
	sameOpcode _ _ = False

checkUnknownOpcodeRejected :: Bool
checkUnknownOpcodeRejected = isNothing (byteToOpcode 0x3) && isNothing (byteToOpcode 0xf)
where
	isNothing Nothing = True
	isNothing (Just _) = False

checkLengthBytesShortForm :: Bool
checkLengthBytesShortForm = size (lengthBytes 0) == 1 && size (lengthBytes 125) == 1

checkLengthBytesExtended16 :: Bool
checkLengthBytesExtended16 = size (lengthBytes 126) == 3 && size (lengthBytes 65535) == 3

checkLengthBytesExtended64 :: Bool
checkLengthBytesExtended64 = size (lengthBytes 65536) == 9

// String literal escapes are kept to the plain, unambiguous ones (this
// project's other Clean modules only rely on \\, \", and \n); every raw
// byte value below is built with `toChar` instead of a hex string escape.
bytesOf :: ![Int] -> String
bytesOf ns = {toChar n \\ n <- ns}

checkMaskIsInvolution :: Bool
checkMaskIsInvolution = maskPayload (maskPayload payload mask) mask == payload
where
	payload = "the quick brown fox"
	mask = bytesOf [1, 2, 3, 4]

checkMaskChangesBytes :: Bool
checkMaskChangesBytes = and [payload.[i] <> masked.[i] \\ i <- [0 .. size payload - 1]]
where
	payload = "aaaaaaaa"
	mask = bytesOf [255, 255, 255, 255]
	masked = maskPayload payload mask

checkValidUtf8Accepted :: Bool
checkValidUtf8Accepted
	= isValidUtf8 "plain ascii"
	&& isValidUtf8 ("caf" +++ bytesOf [0xc3, 0xa9])  // "café", a 2-byte sequence
	&& isValidUtf8 (bytesOf [0xe2, 0x82, 0xac])      // the Euro sign, a 3-byte sequence
	&& isValidUtf8 (bytesOf [0xf0, 0x9f, 0x98, 0x80]) // an emoji, a 4-byte sequence
	&& isValidUtf8 ""

checkInvalidUtf8Rejected :: Bool
checkInvalidUtf8Rejected
	= not (isValidUtf8 (bytesOf [0xc3]))         // a 2-byte sequence's leading byte with no continuation byte at all
	&& not (isValidUtf8 (bytesOf [0xe2, 0x82]))  // a 3-byte sequence truncated after one continuation byte
	&& not (isValidUtf8 (bytesOf [0xc3, 0x28]))  // a continuation byte position holding an ASCII byte instead
	&& not (isValidUtf8 (bytesOf [0x80]))        // a bare continuation byte with no leading byte

checkAcceptKeyMatchesRfcExample :: Bool
checkAcceptKeyMatchesRfcExample = computeAcceptKey "dGhlIHNhbXBsZSBub25jZQ==" == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
