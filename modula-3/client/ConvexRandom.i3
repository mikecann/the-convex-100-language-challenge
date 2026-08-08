(* ConvexRandom - unpredictable bytes, via TlsShim's OpenSSL RAND_bytes
   binding. Used for WebSocket masking keys and the sync protocol's
   Connect sessionId; never for anything TLS itself relies on. *)
INTERFACE ConvexRandom;

EXCEPTION Error;

PROCEDURE Bytes(n: INTEGER): TEXT RAISES {Error};

(* Lowercase-hex encoding of "n" random bytes, for the sessionId. *)
PROCEDURE HexBytes(n: INTEGER): TEXT RAISES {Error};

END ConvexRandom.
