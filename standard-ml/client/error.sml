(* One structured failure type for the whole client.
   The conformance adapter has to report the difference between a function that
   failed, a protocol the server broke, and a transport that died, so failures
   are never flattened into a plain string or a successful value. *)

structure ConvexError =
struct
  type t =
    {name: string,
     message: string,
     data: Json.value,
     logs: string list,
     operation: string option}

  exception Error of t

  fun make {name, message, data, logs, operation} : t =
    {name = name, message = message, data = data, logs = logs, operation = operation}

  fun simple (name, message) : t =
    {name = name, message = message, data = Json.Null, logs = [], operation = NONE}

  fun withOperation (name, message, operation) : t =
    {name = name, message = message, data = Json.Null, logs = [],
     operation = SOME operation}

  fun fail (name, message) = raise Error (simple (name, message))

  (* Bring any exception into a readable form. Poly/ML's exnMessage covers
     library failures; the client's own exceptions carry better text. *)
  fun describe exn =
    case exn of
        Error {message, ...} => message
      | Json.JsonError message => message
      | Fail message => message
      | _ => General.exnMessage exn

  (* Anything that is not already structured is protocol drift by default; the
     transport layers relabel their own failures before this is reached. *)
  fun normalise exn =
    case exn of
        Error record => record
      | _ => simple ("ProtocolError", describe exn)
end
