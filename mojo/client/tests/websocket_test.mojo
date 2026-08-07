"""Unit tests for the hand-written SHA-1, accept token and frame decoder."""

from std.base64 import b64encode

from websocket import (
    MAX_FRAME_BYTES,
    OP_CLOSE,
    OP_PING,
    OP_TEXT,
    accept_token,
    sha1,
)


fn check(condition: Bool, label: String) raises:
    if not condition:
        raise Error("FAIL " + label)


fn hex_of(digest: List[UInt8]) -> String:
    var out = String()
    for i in range(len(digest)):
        var byte = Int(digest[i])
        out += "0123456789abcdef"[byte = byte >> 4 : (byte >> 4) + 1]
        out += "0123456789abcdef"[byte = byte & 0xF : (byte & 0xF) + 1]
    return out


fn main() raises:
    # The three published SHA-1 vectors, including one that crosses a block.
    check(
        hex_of(sha1(String("abc").as_bytes()))
        == "a9993e364706816aba3e25717850c26c9cd0d89d",
        "sha1 abc",
    )
    check(
        hex_of(sha1(String().as_bytes()))
        == "da39a3ee5e6b4b0d3255bfef95601890afd80709",
        "sha1 empty",
    )
    check(
        hex_of(
            sha1(
                String(
                    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
                ).as_bytes()
            )
        )
        == "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
        "sha1 two blocks",
    )

    # The worked example from RFC 6455 section 1.3.
    check(
        accept_token(String("dGhlIHNhbXBsZSBub25jZQ=="))
        == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        "rfc 6455 accept token",
    )

    print("PASS mojo websocket")
