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

let emit_error output ?(id = "") ?subscription_id error =
  let fields =
    match subscription_id with
    | Some value ->
        [ ("type", `String "subscription"); ("subscriptionId", `String value) ]
    | None -> [ ("type", `String "error"); ("id", `String id) ]
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

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name json =
  match member name json with Some (`String value) -> Some value | _ -> None

let serve input output =
  let client = ref None in
  let relays : (string, relay) Hashtbl.t = Hashtbl.create 8 in
  let running = ref true in
  while !running do
    match input_line input with
    | exception End_of_file -> running := false
    | line -> (
        let command = try Some (J.from_string line) with _ -> None in
        match command with
        | None ->
            emit_error output
              (Convex.Protocol_error "malformed adapter command")
        | Some json -> (
            let id =
              match string_field "id" json with
              | Some value -> value
              | None -> ""
            in
            let op =
              match string_field "op" json with
              | Some value -> value
              | None -> ""
            in
            match op with
            | "hello" ->
                if member "protocolVersion" json <> Some (`Int 1) then
                  emit_error output ~id
                    (Convex.Protocol_error
                       "unsupported adapter protocol version")
                else
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
            | "query" | "mutation" | "action" -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    let path =
                      match string_field "path" json with
                      | Some value -> value
                      | None -> ""
                    in
                    let args =
                      match member "args" json with
                      | Some value -> value
                      | None -> `Assoc []
                    in
                    let result =
                      match op with
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
            | "setAuth" -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    match string_field "token" json with
                    | Some token -> (
                        match Convex.set_auth active token with
                        | Ok () -> ack output id
                        | Error error -> emit_error output ~id error)
                    | None ->
                        emit_error output ~id
                          (Convex.Protocol_error "setAuth requires token")))
            | "subscribe" -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    let subscription_id =
                      match string_field "subscriptionId" json with
                      | Some value -> value
                      | None -> ""
                    in
                    (match Hashtbl.find_opt relays subscription_id with
                    | Some old ->
                        stop_relay old;
                        Hashtbl.remove relays subscription_id
                    | None -> ());
                    let path =
                      match string_field "path" json with
                      | Some value -> value
                      | None -> ""
                    in
                    let args =
                      match member "args" json with
                      | Some value -> value
                      | None -> `Assoc []
                    in
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
            | "unsubscribe" ->
                let subscription_id =
                  match string_field "subscriptionId" json with
                  | Some value -> value
                  | None -> ""
                in
                (match Hashtbl.find_opt relays subscription_id with
                | Some relay ->
                    stop_relay relay;
                    Hashtbl.remove relays subscription_id
                | None -> ());
                ack output id
            | "debugDisconnect" -> (
                match ensure_client client with
                | Error error -> emit_error output ~id error
                | Ok active -> (
                    match Convex.debug_disconnect active with
                    | Ok () -> ack output id
                    | Error error -> emit_error output ~id error))
            | "close" ->
                Hashtbl.iter (fun _ relay -> stop_relay relay) relays;
                Hashtbl.clear relays;
                (match !client with
                | Some active -> Convex.close active
                | None -> ());
                emit output
                  (`Assoc [ ("id", `String id); ("type", `String "closed") ]);
                running := false
            | _ ->
                emit_error output ~id
                  (Convex.Protocol_error "unknown adapter operation")))
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
        if host = "localhost" then Unix.inet_addr_loopback
        else Unix.inet_addr_of_string host
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
