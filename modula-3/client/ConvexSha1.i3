(* ConvexSha1 - SHA-1 (FIPS 180-1), used only for the WebSocket
   handshake's Sec-WebSocket-Accept check (RFC 6455 section 1.3). This
   is not used for anything security-sensitive: TLS certificate
   verification is entirely OpenSSL's, through TlsShim. *)
INTERFACE ConvexSha1;

(* Raw (not hex, not base64) 20-byte digest of "s", as a 20-character
   TEXT byte string. *)
PROCEDURE Digest(s: TEXT): TEXT;

END ConvexSha1.
