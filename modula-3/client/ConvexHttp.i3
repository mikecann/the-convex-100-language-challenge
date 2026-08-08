(* ConvexHttp - the Convex JSON HTTP API: POST /api/{query,mutation,
   action} with a {"path","args","format":"json"} body, an optional
   bearer token, and Convex's own {"status": "success"|"error", ...}
   response envelope. This module owns HTTP/1.1 request framing and
   response parsing (status line, headers, Content-Length, chunked
   transfer encoding, and connection-close-terminated bodies); it knows
   nothing about WebSockets or the sync protocol. *)
INTERFACE ConvexHttp;

IMPORT ConvexJson;

TYPE
  ResultKind = {Result, FunctionError, TransportError, ProtocolError};

  CallResult = RECORD
    kind: ResultKind;
    value: ConvexJson.T;    (* set iff kind = Result *)
    errName: TEXT;          (* set iff kind # Result *)
    errMessage: TEXT;       (* set iff kind # Result *)
    errData: ConvexJson.T;  (* may be NIL even when kind = FunctionError *)
    logLines: ConvexJson.T; (* an array, possibly empty, never NIL *)
  END;

(* "op" is "query", "mutation", or "action". "baseUrl" is the bare
   "https://host[:port]" (or "http://" for the local self-hosted
   backend) deployment URL. "token" is the bearer auth token, or "" to
   send none. *)
PROCEDURE Call(op: TEXT; path: TEXT; args: ConvexJson.T; baseUrl: TEXT; token: TEXT): CallResult;

END ConvexHttp.
