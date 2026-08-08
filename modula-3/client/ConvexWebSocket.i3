(* ConvexWebSocket - RFC 6455 framing and the HTTP upgrade handshake.
   This module knows nothing about the Convex sync protocol or JSON; it
   only turns a ConvexTransport.T into a place to send and receive raw
   WebSocket frames. Fragmentation reassembly, interleaved control
   frames, and once-after-reassembly UTF-8 validation are the caller's
   job (ConvexLive), since only the caller knows when a logical message
   is actually complete. *)
INTERFACE ConvexWebSocket;

IMPORT ConvexTransport;

EXCEPTION Error(TEXT);

CONST
  OpContinuation = 16_0;
  OpText = 16_1;
  OpBinary = 16_2;
  OpClose = 16_8;
  OpPing = 16_9;
  OpPong = 16_A;

TYPE
  Frame = RECORD
    fin: BOOLEAN;
    opcode: INTEGER;
    payload: TEXT;
  END;

  (* Result of trying to parse one frame out of an accumulated byte
     buffer: "ok" is FALSE when more bytes are needed. When "ok" is
     TRUE, "consumed" is how many leading bytes of the buffer this
     frame used (the caller drops them before parsing further). *)
  ParseResult = RECORD
    ok: BOOLEAN;
    consumed: INTEGER;
    frame: Frame;
  END;

(* Connect a WebSocket over "t" (already TCP/TLS-connected) at "host"/
   "path", waiting no longer than "deadline" (a Time.Now()-scale
   value). Returns any bytes already read past the handshake response
   -- the start of the first WebSocket frame, if the server sent one
   immediately. Raises Error on any handshake failure, including a
   Sec-WebSocket-Accept mismatch. *)
PROCEDURE Handshake(t: ConvexTransport.T; host: TEXT; path: TEXT; deadline: LONGREAL): TEXT
  RAISES {Error};

(* Build one complete, unfragmented, masked frame ready to write to the
   transport. This client never needs to fragment an outgoing message:
   every sync-protocol message it sends fits in one frame. *)
PROCEDURE BuildFrame(opcode: INTEGER; payload: TEXT): TEXT;

(* Try to parse one frame from the front of "buf". A masked frame from
   the server (never legal per RFC 6455 section 5.1) raises Error. *)
PROCEDURE TryParseFrame(buf: TEXT): ParseResult RAISES {Error};

END ConvexWebSocket.
