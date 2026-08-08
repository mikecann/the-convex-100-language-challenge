(* ConvexUtf8 - validates that a byte string is well-formed UTF-8, per
   RFC 6455's requirement that a WebSocket text message's payload be
   validated as UTF-8 exactly once, after any fragmentation has been
   fully reassembled (validating each fragment separately would wrongly
   reject a multi-byte sequence split across a frame boundary). *)
INTERFACE ConvexUtf8;

PROCEDURE IsValid(s: TEXT): BOOLEAN;

END ConvexUtf8.
