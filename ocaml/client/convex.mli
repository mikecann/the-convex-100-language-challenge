type result = { value : Yojson.Safe.t; logs : string list }

type error =
  | Function_error of {
      operation : string;
      message : string;
      data : Yojson.Safe.t option;
      logs : string list;
    }
  | Protocol_error of string
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

val create : string -> (client, error) Stdlib.result
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
val close : client -> unit
val parse_integral_int64 : Yojson.Safe.t -> (int64, string) Stdlib.result
