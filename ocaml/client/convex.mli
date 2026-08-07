type result = { value : Yojson.Safe.t; logs : string list }

type error =
  | Function_error of {
      operation : string;
      message : string;
      data : Yojson.Safe.t option;
      logs : string list;
    }
  | Protocol_error of string
  | Http_error of { operation : string; status_code : int; message : string }
  | Transport_error of { operation : string; message : string }
  | Closed

val error_name : error -> string
val error_message : error -> string
val error_data : error -> Yojson.Safe.t option
val error_logs : error -> string list

type update = {
  value : Yojson.Safe.t option;
  error : error option;
  logs : string list;
}

type client
type subscription

val create : ?http_timeout:float -> string -> (client, error) Stdlib.result
val set_auth : client -> string -> (unit, error) Stdlib.result
val query : client -> string -> Yojson.Safe.t -> (result, error) Stdlib.result

val mutation :
  client -> string -> Yojson.Safe.t -> (result, error) Stdlib.result

val action : client -> string -> Yojson.Safe.t -> (result, error) Stdlib.result

val subscribe :
  client -> string -> Yojson.Safe.t -> (subscription, error) Stdlib.result

val subscription_next :
  subscription -> float -> (update option, error) Stdlib.result

val unsubscribe : subscription -> (unit, error) Stdlib.result

val debug_disconnect : client -> (unit, error) Stdlib.result
(** Force the live connection closed and let the socket owner reconnect on its
    own, without closing the client. Exposed only because the conformance
    adapter's [debugDisconnect] operation exercises this client's
    reconnect-and-recover path the same way every other language's adapter does;
    application code has no reason to call it, and closing the connection out
    from under a live subscription is not a capability this client otherwise
    offers. *)

val close : client -> unit
val parse_integral_int64 : Yojson.Safe.t -> (int64, string) Stdlib.result

val utf8_scalar_count : string -> int option
(** Number of Unicode scalars in a valid UTF-8 string, or [None] when the bytes
    are not well-formed UTF-8. Exposed because the adapter schema's string
    lengths are character counts, so the test-only conformance executable must
    measure them the same way this client measures sync protocol text rather
    than growing a second, divergent decoder. *)

val websocket_accept_key : string -> string
(** The RFC 6455 [Sec-WebSocket-Accept] value for a client key. Exposed so the
    language-local WebSocket fixtures can answer a handshake correctly and so
    the published RFC vector can pin this implementation from a test. *)
