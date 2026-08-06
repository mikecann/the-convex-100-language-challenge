module J = Yojson.Safe

type output = { channel : out_channel; mutex : Mutex.t }

let emit output json =
  Mutex.lock output.mutex;
  output_string output.channel (J.to_string json ^ "\n");
  flush output.channel;
  Mutex.unlock output.mutex

let error_json error =
  let fields =
    [
      ("name", `String (Convex.error_name error));
      ("message", `String (Convex.error_message error));
    ]
  in
  let fields =
    match Convex.error_data error with
    | None -> fields
    | Some data -> ("data", data) :: fields
  in
  `Assoc (List.rev fields)

let emit_error output ?id ?subscription_id error =
  let fields =
    match (subscription_id, id) with
    | Some value, _ ->
        [ ("type", `String "subscription"); ("subscriptionId", `String value) ]
    | None, Some value -> [ ("type", `String "error"); ("id", `String value) ]
    | None, None -> [ ("type", `String "error") ]
  in
  let fields = ("error", error_json error) :: fields in
  let logs = Convex.error_logs error in
  let fields =
    if logs = [] then fields
    else ("logs", `List (List.map (fun line -> `String line) logs)) :: fields
  in
  emit output (`Assoc (List.rev fields))

let ack output id =
  emit output (`Assoc [ ("id", `String id); ("type", `String "ack") ])

type relay = {
  id : string;
  subscription : Convex.subscription;
  mutable active : bool;
  mutable generation : int;
  mutex : Mutex.t;
  mutable thread : Thread.t option;
}

let start_relay output relay =
  let generation = relay.generation in
  let thread =
    Thread.create
      (fun () ->
        let rec loop () =
          match Convex.subscription_next relay.subscription (-1.0) with
          | Error error -> emit_error output ~subscription_id:relay.id error
          | Ok None -> ()
          | Ok (Some update) ->
              Mutex.lock relay.mutex;
              let publish = relay.active && relay.generation = generation in
              if publish then (
                (match update.error with
                | Some error ->
                    emit_error output ~subscription_id:relay.id error
                | None ->
                    let fields =
                      [
                        ("type", `String "subscription");
                        ("subscriptionId", `String relay.id);
                        ( "value",
                          match update.value with
                          | Some value -> value
                          | None -> `Null );
                      ]
                    in
                    let fields =
                      if update.logs = [] then fields
                      else
                        ( "logs",
                          `List
                            (List.map (fun line -> `String line) update.logs) )
                        :: fields
                    in
                    emit output (`Assoc fields));
                Mutex.unlock relay.mutex;
                loop ())
              else (
                Mutex.unlock relay.mutex;
                loop ())
        in
        loop ())
      ()
  in
  relay.thread <- Some thread

let stop_relay relay =
  Mutex.lock relay.mutex;
  relay.active <- false;
  relay.generation <- relay.generation + 1;
  Mutex.unlock relay.mutex;
  ignore (Convex.unsubscribe relay.subscription);
  match relay.thread with Some thread -> Thread.join thread | None -> ()

let ensure_client client =
  match !client with
  | Some value -> Ok value
  | None -> (
      match Sys.getenv_opt "CONVEX_URL" with
      | None -> Error (Convex.Protocol_error "CONVEX_URL is required")
      | Some url -> (
          match Convex.create url with
          | Error error -> Error error
          | Ok value ->
              (match Sys.getenv_opt "CONVEX_AUTH_TOKEN" with
              | Some token -> ignore (Convex.set_auth value token)
              | None -> ());
              client := Some value;
              Ok value))

type command =
  | Hello of string
  | Call of { id : string; operation : string; path : string; args : J.t }
  | Set_auth of { id : string; token : string }
  | Subscribe of {
      id : string;
      subscription_id : string;
      path : string;
      args : J.t;
    }
  | Unsubscribe of { id : string; subscription_id : string }
  | Debug_disconnect of string
  | Close of string

let valid_id value =
  let length = String.length value in
  length >= 1 && length <= 128

let occurrences name fields =
  List.filter_map
    (fun (key, value) -> if key = name then Some value else None)
    fields

let command_id fields =
  match occurrences "id" fields with
  | [ `String value ] when valid_id value -> Ok value
  | [] -> Error "adapter command omitted id"
  | [ `String _ ] -> Error "adapter command id must contain 1 to 128 bytes"
  | [ _ ] -> Error "adapter command id must be a string"
  | _ -> Error "adapter command contains duplicate id fields"

let field name fields =
  match occurrences name fields with
  | [ value ] -> Ok value
  | [] -> Error ("adapter command omitted " ^ name)
  | _ -> Error ("adapter command contains duplicate " ^ name ^ " fields")

let optional_field name fields =
  match occurrences name fields with
  | [ value ] -> Ok (Some value)
  | [] -> Ok None
  | _ -> Error ("adapter command contains duplicate " ^ name ^ " fields")

let no_extra_fields allowed fields =
  match List.find_opt (fun (name, _) -> not (List.mem name allowed)) fields with
  | Some (name, _) -> Error ("adapter command has unexpected field " ^ name)
  | None -> Ok ()

let string_value name = function
  | `String value -> Ok value
  | _ -> Error ("adapter command " ^ name ^ " must be a string")

let id_value name = function
  | `String value when valid_id value -> Ok value
  | `String _ ->
      Error ("adapter command " ^ name ^ " must contain 1 to 128 bytes")
  | _ -> Error ("adapter command " ^ name ^ " must be a string")

let object_value name = function
  | `Assoc _ as value -> Ok value
  | _ -> Error ("adapter command " ^ name ^ " must be an object")

let parse_command json =
  match json with
  | `Assoc fields -> (
      match command_id fields with
      | Error message -> Error (None, message)
      | Ok id -> (
          let fail message = Error (Some id, message) in
          match field "op" fields with
          | Error message -> fail message
          | Ok op_json -> (
              match string_value "op" op_json with
              | Error message -> fail message
              | Ok op -> (
                  let finish allowed build =
                    match no_extra_fields allowed fields with
                    | Error message -> fail message
                    | Ok () -> build ()
                  in
                  match op with
                  | "hello" ->
                      finish [ "protocolVersion"; "id"; "op" ] (fun () ->
                          match field "protocolVersion" fields with
                          | Ok (`Int 1) -> Ok (Hello id)
                          | Ok _ -> fail "unsupported adapter protocol version"
                          | Error message -> fail message)
                  | "query" | "mutation" | "action" ->
                      finish [ "id"; "op"; "path"; "args" ] (fun () ->
                          match (field "path" fields, field "args" fields) with
                          | Error message, _ | _, Error message -> fail message
                          | Ok path_json, Ok args_json -> (
                              match
                                ( string_value "path" path_json,
                                  object_value "args" args_json )
                              with
                              | Error message, _ | _, Error message ->
                                  fail message
                              | Ok path, Ok _ when String.length path < 3 ->
                                  fail
                                    "adapter command path must contain at \
                                     least 3 bytes"
                              | Ok path, Ok args ->
                                  Ok (Call { id; operation = op; path; args })))
                  | "setAuth" ->
                      finish [ "id"; "op"; "token" ] (fun () ->
                          match field "token" fields with
                          | Error message -> fail message
                          | Ok token_json -> (
                              match string_value "token" token_json with
                              | Error message -> fail message
                              | Ok token -> Ok (Set_auth { id; token })))
                  | "subscribe" ->
                      finish [ "id"; "op"; "subscriptionId"; "path"; "args" ]
                        (fun () ->
                          match
                            ( field "subscriptionId" fields,
                              optional_field "path" fields,
                              optional_field "args" fields )
                          with
                          | Error message, _, _
                          | _, Error message, _
                          | _, _, Error message ->
                              fail message
                          | Ok subscription_json, Ok path_json, Ok args_json
                            -> (
                              match
                                ( id_value "subscriptionId" subscription_json,
                                  (match path_json with
                                  | None -> Ok ""
                                  | Some value -> string_value "path" value),
                                  match args_json with
                                  | None -> Ok (`Assoc [])
                                  | Some value -> object_value "args" value )
                              with
                              | Error message, _, _
                              | _, Error message, _
                              | _, _, Error message ->
                                  fail message
                              | Ok subscription_id, Ok path, Ok args ->
                                  Ok
                                    (Subscribe
                                       { id; subscription_id; path; args })))
                  | "unsubscribe" ->
                      finish [ "id"; "op"; "subscriptionId"; "path"; "args" ]
                        (fun () ->
                          match
                            ( field "subscriptionId" fields,
                              optional_field "path" fields,
                              optional_field "args" fields )
                          with
                          | Error message, _, _
                          | _, Error message, _
                          | _, _, Error message ->
                              fail message
                          | Ok subscription_json, Ok path_json, Ok args_json
                            -> (
                              match
                                ( id_value "subscriptionId" subscription_json,
                                  (match path_json with
                                  | None -> Ok ()
                                  | Some value ->
                                      Result.map
                                        (fun _ -> ())
                                        (string_value "path" value)),
                                  match args_json with
                                  | None -> Ok ()
                                  | Some value ->
                                      Result.map
                                        (fun _ -> ())
                                        (object_value "args" value) )
                              with
                              | Error message, _, _
                              | _, Error message, _
                              | _, _, Error message ->
                                  fail message
                              | Ok subscription_id, Ok (), Ok () ->
                                  Ok (Unsubscribe { id; subscription_id })))
                  | "debugDisconnect" ->
                      finish [ "id"; "op" ] (fun () -> Ok (Debug_disconnect id))
                  | "close" -> finish [ "id"; "op" ] (fun () -> Ok (Close id))
                  | _ -> fail "unknown adapter operation"))))
  | _ -> Error (None, "adapter command must be a JSON object")

let serve input output =
  let client = ref None in
  let relays : (string, relay) Hashtbl.t = Hashtbl.create 8 in
  let running = ref true in
  while !running do
    match input_line input with
    | exception End_of_file -> running := false
    | line -> (
        let json = try Some (J.from_string line) with _ -> None in
        match json with
        | None ->
            emit_error output
              (Convex.Protocol_error "malformed adapter command")
        | Some json -> (
            match parse_command json with
            | Error (id, message) ->
                emit_error output ?id (Convex.Protocol_error message)
            | Ok (Hello id) ->
                emit output
                  (`Assoc
                     [
                       ("protocolVersion", `Int 1);
                       ("id", `String id);
                       ("type", `String "ready");
                       ("language", `String "ocaml");
                       ( "implementation",
                         `String "native-ocaml-unix-ssl-yojson-websocket" );
                       ("runtime", `String Sys.ocaml_version);
                     ])
            | Ok (Call { id; operation; path; args }) -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    let result =
                      match operation with
                      | "query" -> Convex.query active path args
                      | "mutation" -> Convex.mutation active path args
                      | _ -> Convex.action active path args
                    in
                    match result with
                    | Error error -> emit_error output ~id error
                    | Ok result ->
                        let fields =
                          [
                            ("id", `String id);
                            ("type", `String "result");
                            ("value", result.value);
                          ]
                        in
                        let fields =
                          if result.logs = [] then fields
                          else
                            ( "logs",
                              `List
                                (List.map
                                   (fun line -> `String line)
                                   result.logs) )
                            :: fields
                        in
                        emit output (`Assoc fields)))
            | Ok (Set_auth { id; token }) -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    match Convex.set_auth active token with
                    | Ok () -> ack output id
                    | Error error -> emit_error output ~id error))
            | Ok (Subscribe { id; subscription_id; path; args }) -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    (match Hashtbl.find_opt relays subscription_id with
                    | Some old ->
                        stop_relay old;
                        Hashtbl.remove relays subscription_id
                    | None -> ());
                    match Convex.subscribe active path args with
                    | Error error -> emit_error output ~id error
                    | Ok subscription ->
                        let relay =
                          {
                            id = subscription_id;
                            subscription;
                            active = true;
                            generation = 1;
                            mutex = Mutex.create ();
                            thread = None;
                          }
                        in
                        Hashtbl.replace relays subscription_id relay;
                        start_relay output relay;
                        ack output id))
            | Ok (Unsubscribe { id; subscription_id }) ->
                (match Hashtbl.find_opt relays subscription_id with
                | Some relay ->
                    stop_relay relay;
                    Hashtbl.remove relays subscription_id
                | None -> ());
                ack output id
            | Ok (Debug_disconnect id) -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    match Convex.debug_disconnect active with
                    | Ok () -> ack output id
                    | Error error -> emit_error output ~id error))
            | Ok (Close id) ->
                Hashtbl.iter (fun _ relay -> stop_relay relay) relays;
                Hashtbl.clear relays;
                (match !client with
                | Some active -> Convex.close active
                | None -> ());
                emit output
                  (`Assoc [ ("id", `String id); ("type", `String "closed") ]);
                running := false))
  done

let () =
  match Sys.getenv_opt "ADAPTER_LISTEN" with
  | None -> serve stdin { channel = stdout; mutex = Mutex.create () }
  | Some address ->
      let separator =
        match String.rindex_opt address ':' with
        | Some value -> value
        | None -> raise (Failure "ADAPTER_LISTEN must be host:port")
      in
      let host = String.sub address 0 separator in
      let port =
        int_of_string
          (String.sub address (separator + 1)
             (String.length address - separator - 1))
      in
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      let inet =
        match host with
        | "localhost" -> Unix.inet_addr_loopback
        (* An omitted host means "every interface", which is what the shared
           controller asks for when it forwards a port into the container. *)
        | "" | "*" -> Unix.inet_addr_any
        | value -> Unix.inet_addr_of_string value
      in
      Unix.bind socket (Unix.ADDR_INET (inet, port));
      Unix.listen socket 1;
      let client_socket, _ = Unix.accept socket in
      Unix.close socket;
      serve
        (Unix.in_channel_of_descr client_socket)
        {
          channel = Unix.out_channel_of_descr client_socket;
          mutex = Mutex.create ();
        }
