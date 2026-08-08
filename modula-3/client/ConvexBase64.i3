(* ConvexBase64 - standard (RFC 4648) base64 encoding and decoding.
   Encode is used for the WebSocket handshake key and the digest
   compared against the server's Sec-WebSocket-Accept; Decode is used
   only to read Convex's opaque base64-encoded logical timestamp
   cursor back into raw bytes for maxObservedTimestamp comparison. *)
INTERFACE ConvexBase64;

EXCEPTION Error;

PROCEDURE Encode(s: TEXT): TEXT;
PROCEDURE Decode(s: TEXT): TEXT RAISES {Error};

END ConvexBase64.
