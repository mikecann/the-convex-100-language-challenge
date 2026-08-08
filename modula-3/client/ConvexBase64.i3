(* ConvexBase64 - standard (RFC 4648) base64 encoding. The client only
   ever needs to produce base64 (the WebSocket handshake key and the
   digest compared against the server's Sec-WebSocket-Accept), never
   parse it, so this is encode-only. *)
INTERFACE ConvexBase64;

PROCEDURE Encode(s: TEXT): TEXT;

END ConvexBase64.
