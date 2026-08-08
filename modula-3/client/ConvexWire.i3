(* ConvexWire - small pieces shared by ConvexHttp's response parsing and
   ConvexWebSocket's upgrade-handshake parsing: both read an HTTP-style
   block of "status-line CRLF headers CRLF CRLF" off a ConvexTransport.T
   within a byte budget and a deadline, then look values up by header
   name. Neither module needs to know how the other does this, so it
   lives here instead of being copied twice. *)
INTERFACE ConvexWire;

IMPORT ConvexTransport;

EXCEPTION Error(TEXT);

TYPE
  HeaderBlock = RECORD
    statusLine: TEXT;
    (* the raw "Name: value\r\n..." lines, unparsed *)
    headerText: TEXT;
    (* any bytes already read past the blank line terminator -- the
       start of the response body, or of WebSocket frame data *)
    leftover: TEXT;
  END;

(* Index of the first occurrence of "needle" in "s" at or after "from",
   or -1. *)
PROCEDURE Find(s: TEXT; needle: TEXT; from: CARDINAL): INTEGER;

(* Read from "t" until a blank-line-terminated header block has
   arrived, waiting no longer than "deadline" (a ConvexTime.NowMs()
   value) and no more than "maxBytes" total. *)
PROCEDURE ReadHeaderBlock(t: ConvexTransport.T; deadline: LONGREAL; maxBytes: INTEGER): HeaderBlock
  RAISES {Error};

(* Case-insensitive lookup of header "name" in "headerText" (as
   returned in HeaderBlock.headerText). NIL if absent. The returned
   value has leading/trailing spaces and tabs trimmed. *)
PROCEDURE HeaderValue(headerText: TEXT; name: TEXT): TEXT;

END ConvexWire.
