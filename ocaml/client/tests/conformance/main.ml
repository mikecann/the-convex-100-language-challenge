module J = Yojson.Safe

(* The conformance adapter shares the client's monotonic clock so an output
   deadline cannot be extended or expired by a wall-clock change. *)
external monotonic_now : unit -> float = "convex_monotonic_now"

(* ---------------------------------------------------------------------------
   Bounded NDJSON input

   The controller's commands arrive as newline-delimited JSON on stdin or on a
   single accepted TCP connection. Reading a line with an unbounded buffer
   means the peer chooses how much memory this process allocates before the
   first byte is ever parsed, so the limit is applied while the bytes are being
   consumed: past it the remainder of the line is counted and discarded rather
   than accumulated, and the stream stays usable for the next command. *)
let max_command_bytes = 4 * 1024 * 1024

type reader = {
  r_fd : Unix.file_descr;
  r_block : Bytes.t;
  mutable r_length : int;
  mutable r_offset : int;
  mutable r_eof : bool;
}

let create_reader fd =
  {
    r_fd = fd;
    r_block = Bytes.create 65536;
    r_length = 0;
    r_offset = 0;
    r_eof = false;
  }

let refill reader =
  let rec read () =
    match
      Unix.read reader.r_fd reader.r_block 0 (Bytes.length reader.r_block)
    with
    | 0 ->
        reader.r_length <- 0;
        reader.r_offset <- 0;
        reader.r_eof <- true
    | count ->
        reader.r_length <- count;
        reader.r_offset <- 0
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
        (* In TCP mode the accepted socket is shared with the writer, which
           needs it non-blocking, so an empty read waits here instead. *)
        ignore (Unix.select [ reader.r_fd ] [] [] (-1.0));
        read ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
  in
  read ()

type command_line = Line of string | Overlong | Eof

let read_command_line reader =
  let buffer = Buffer.create 256 in
  let overlong = ref false in
  let finish () =
    if !overlong then Overlong else Line (Buffer.contents buffer)
  in
  let rec loop () =
    if reader.r_offset >= reader.r_length then
      if reader.r_eof then
        if !overlong || Buffer.length buffer > 0 then finish () else Eof
      else (
        refill reader;
        loop ())
    else
      let char = Bytes.get reader.r_block reader.r_offset in
      reader.r_offset <- reader.r_offset + 1;
      if char = '\n' then finish ()
      else (
        if !overlong then ()
        else if Buffer.length buffer >= max_command_bytes then (
          overlong := true;
          Buffer.clear buffer)
        else Buffer.add_char buffer char;
        loop ())
  in
  loop ()

(* ---------------------------------------------------------------------------
   One bounded, ordered writer

   Every event leaves through this queue, and only the writer thread touches
   the output descriptor. Two properties matter and neither survives writing
   directly from the threads that produce events:

   - A relay thread must never block on output while it holds the relay mutex,
     because a controller that has stopped reading would then also block
     unsubscribe and close, which take that same mutex.
   - A stalled controller must not be able to grow this process without bound,
     so the queue has a byte budget and producers wait for room before they
     decide to publish, not after.

   One NDJSON line gets one deadline that covers all of its partial writes. If
   that deadline expires, or the descriptor fails, the line on the wire may be
   half a JSON object; nothing after it could be parsed as protocol, so the
   stream is terminal from that point and the process reports the failure on
   stderr rather than emitting anything further.

   Room is reserved before an event is taken from the client, not after. A
   producer that took the value first would hold a near-maximum value, and then
   a second copy of it as an encoded line, for as long as it waited for room,
   and there is one producer per subscription: the controller would be choosing
   how much memory this process uses. Reserving first makes the number of
   producers holding a value at once a function of this budget instead, so the
   whole output path costs at most three concurrent producers.

   What the client reserves for this process out of the shared container budget
   has to keep agreeing with what this number implies: eight megabytes of
   queued lines, one more line in the writer's hands, and one value plus one
   encoding per producer that holds a slot.

   Lowering it narrows how many producers can be encoding at once, which is the
   point, but it must stay wide enough for one whole event plus one queued
   behind it: a producer waits for room without giving up, and [stop_relay]
   joins a relay thread that may be doing exactly that, so a budget that cannot
   admit a single near-maximum event alongside the queue is one in which an
   unsubscribe waits on a relay that is waiting on the unsubscribe. *)
let max_output_bytes = 8 * 1024 * 1024
let max_event_bytes = (2 * 1024 * 1024) + 65536
let output_line_timeout = 10.0

type writer = {
  w_fd : Unix.file_descr;
  w_mutex : Mutex.t;
  (* Signalled whenever room changes hands or the turn moves, so a producer
     waiting for room sleeps until something it cares about happened rather
     than until a timer it chose expired. *)
  w_room : Condition.t;
  w_lines : string Queue.t;
  mutable w_queued : int;
  mutable w_reserved : int;
  mutable w_stopping : bool;
  mutable w_terminal : bool;
  (* Producers are served strictly in the order they asked. A relay re-enters
     [reserve] the instant it lets go of a slot, so without an order the
     producers that never pause hold every slot between them and one that has
     to wait is never served at all. *)
  mutable w_next_ticket : int;
  mutable w_serving : int;
}

let create_writer fd =
  Unix.set_nonblock fd;
  {
    w_fd = fd;
    w_mutex = Mutex.create ();
    w_room = Condition.create ();
    w_lines = Queue.create ();
    w_queued = 0;
    w_reserved = 0;
    w_stopping = false;
    w_terminal = false;
    w_next_ticket = 0;
    w_serving = 0;
  }

let with_writer writer f =
  Mutex.lock writer.w_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock writer.w_mutex) f

(* Reserving room can wait, so callers reserve before taking any other lock. A
   line larger than the whole budget is still allowed through once the queue is
   empty; refusing it would deadlock instead of bounding anything.

   The wait is a ticket queue rather than a retry loop. Twenty-four relays and
   one command loop compete for the three slots this budget holds, and a relay
   gives its slot back and asks for another with nothing in between, so any
   producer that has to wait its turn under a retry loop can be passed over
   indefinitely. That is not a slow acknowledgement, it is one that never
   arrives: the command loop is sequential, so a subscribe acknowledgement it
   cannot publish stops it reading the next command at all. *)
let reserve writer size =
  Mutex.lock writer.w_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock writer.w_mutex)
    (fun () ->
      let ticket = writer.w_next_ticket in
      writer.w_next_ticket <- ticket + 1;
      let rec wait () =
        if writer.w_terminal then (
          (* Nothing will be written again, so hand the turn on rather than
             leaving it with a producer that is about to walk away. *)
          if writer.w_serving = ticket then (
            writer.w_serving <- ticket + 1;
            Condition.broadcast writer.w_room);
          false)
        else if
          writer.w_serving = ticket
          && (writer.w_queued + writer.w_reserved = 0
             || writer.w_queued + writer.w_reserved + size <= max_output_bytes)
        then (
          writer.w_reserved <- writer.w_reserved + size;
          writer.w_serving <- ticket + 1;
          Condition.broadcast writer.w_room;
          true)
        else (
          Condition.wait writer.w_room writer.w_mutex;
          wait ())
      in
      wait ())

let commit writer size line =
  with_writer writer (fun () ->
      writer.w_reserved <- writer.w_reserved - size;
      if not writer.w_terminal then (
        Queue.push line writer.w_lines;
        writer.w_queued <- writer.w_queued + String.length line);
      Condition.broadcast writer.w_room)

let release writer size =
  with_writer writer (fun () ->
      writer.w_reserved <- writer.w_reserved - size;
      Condition.broadcast writer.w_room)

(* The line goes out of the string the queue already holds. A [Bytes.of_string]
   here would be a second copy of a near-maximum event, alive for the whole ten
   second deadline precisely when a controller has stopped reading, and it is
   not a copy the output budget knows about. *)
let write_line writer line =
  let total = String.length line in
  let deadline = monotonic_now () +. output_line_timeout in
  let partial = ref false in
  let rec loop position =
    if position >= total then true
    else
      let remaining = deadline -. monotonic_now () in
      if remaining <= 0.0 then false
      else
        match
          Unix.single_write_substring writer.w_fd line position
            (total - position)
        with
        | 0 -> false
        | count ->
            if position + count < total then partial := true;
            loop (position + count)
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
            ignore (Unix.select [] [ writer.w_fd ] [] remaining);
            loop position
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop position
        | exception Unix.Unix_error _ -> false
  in
  let completed = loop 0 in
  (completed, !partial)

let writer_loop writer =
  let rec loop () =
    let next =
      with_writer writer (fun () ->
          if writer.w_terminal then `Stop
          else if Queue.is_empty writer.w_lines then
            if writer.w_stopping then `Stop else `Idle
          else
            let line = Queue.pop writer.w_lines in
            writer.w_queued <- writer.w_queued - String.length line;
            Condition.broadcast writer.w_room;
            `Line line)
    in
    match next with
    | `Stop -> ()
    | `Idle ->
        Thread.delay 0.002;
        loop ()
    | `Line line ->
        let completed, partial = write_line writer line in
        if completed then loop ()
        else (
          with_writer writer (fun () ->
              writer.w_terminal <- true;
              Queue.clear writer.w_lines;
              writer.w_queued <- 0;
              (* Everyone waiting for room has to learn there will never be
                 any, or the process exits with producers still blocked. *)
              Condition.broadcast writer.w_room);
          prerr_endline
            ("convex-adapter: NDJSON output stalled"
            ^ (if partial then " after a partial line" else "")
            ^ "; the stream is terminal");
          flush stderr;
          (* Nothing coherent can follow a truncated protocol line, and the
             command loop is blocked on an input the controller is no longer
             servicing, so failing the process is the only honest end. *)
          exit 1)
  in
  loop ()

let stop_writer writer thread =
  with_writer writer (fun () -> writer.w_stopping <- true);
  Thread.join thread

(* The terminator is appended inside the encoder's own buffer. [J.to_string
   json ^ "\n"] would encode into a buffer, copy that buffer out, and then copy
   the result again just to add one byte: three near-maximum strings alive at
   once for what the budget reserves room for one of. *)
let encode_line json =
  let buffer = Buffer.create 1024 in
  J.to_buffer buffer json;
  Buffer.add_char buffer '\n';
  Buffer.contents buffer

let emit writer json =
  if reserve writer max_event_bytes then
    commit writer max_event_bytes (encode_line json)

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

let error_event ?id ?subscription_id error =
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
  `Assoc (List.rev fields)

let ack_event id = `Assoc [ ("id", `String id); ("type", `String "ack") ]

let subscription_event id (update : Convex.update) =
  match update.error with
  | Some error -> error_event ~subscription_id:id error
  | None ->
      let fields =
        [
          ("type", `String "subscription");
          ("subscriptionId", `String id);
          ( "value",
            match update.value with Some value -> value | None -> `Null );
        ]
      in
      if update.logs = [] then `Assoc fields
      else
        `Assoc
          (("logs", `List (List.map (fun line -> `String line) update.logs))
          :: fields)

type relay = {
  id : string;
  subscription : Convex.subscription;
  mutable active : bool;
  mutable generation : int;
  mutex : Mutex.t;
  mutable thread : Thread.t option;
}

(* A relay holds an output slot while it takes one update, never while it waits
   for one. Reserving before taking is what stops a producer holding a
   near-maximum value it has no room to publish, but waiting for something to
   publish costs no memory and so needs no room.

   Reserving across a blocking poll is what made an idle subscription able to
   keep a slot away from a busy one: the relay held a slot for the whole poll
   and asked for another the instant it let go, and this budget holds three
   slots. With twenty-four subscriptions the relays held every slot
   continuously between them while having nothing whatever to send, and the
   command loop - which is sequential, and publishes each acknowledgement
   before reading the next command - stopped dead partway through the
   subscribe batch. The pause below is deliberately outside the reservation.

   The decision to publish is still made under the relay's own mutex with the
   room already reserved, which keeps that critical section free of anything
   that could block and keeps it atomic against invalidation. *)
let relay_poll_timeout = 0.0
let relay_idle_pause = 0.01

let start_relay writer relay =
  let generation = relay.generation in
  let publish () = relay.active && relay.generation = generation in
  let still_wanted () =
    Mutex.lock relay.mutex;
    let wanted = publish () in
    Mutex.unlock relay.mutex;
    wanted
  in
  let deliver json =
    let line = encode_line json in
    Mutex.lock relay.mutex;
    if publish () then commit writer max_event_bytes line
    else release writer max_event_bytes;
    Mutex.unlock relay.mutex
  in
  let thread =
    Thread.create
      (fun () ->
        let rec loop () =
          if reserve writer max_event_bytes then
            match
              Convex.subscription_next relay.subscription relay_poll_timeout
            with
            | Error error ->
                deliver (error_event ~subscription_id:relay.id error)
            | Ok None ->
                release writer max_event_bytes;
                if still_wanted () then (
                  Thread.delay relay_idle_pause;
                  loop ())
            | Ok (Some update) ->
                deliver (subscription_event relay.id update);
                loop ()
        in
        loop ())
      ()
  in
  relay.thread <- Some thread

(* Invalidation happens first and under the relay mutex, so once this returns
   no committed line from the old relay can follow the acknowledgement its
   caller is about to publish. *)
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

(* The adapter schema bounds string lengths the way JSON Schema does, in
   characters rather than in bytes. A UTF-8 id of 128 accented characters is
   256 bytes and is valid; measuring bytes would reject it. Bytes that are not
   well-formed UTF-8 have no character length at all, so they are rejected. *)
let scalar_length value =
  match Convex.utf8_scalar_count value with Some count -> count | None -> -1

let valid_id value =
  let count = scalar_length value in
  count >= 1 && count <= 128

let occurrences name fields =
  List.filter_map
    (fun (key, value) -> if key = name then Some value else None)
    fields

let command_id fields =
  match occurrences "id" fields with
  | [ `String value ] when valid_id value -> Ok value
  | [] -> Error "adapter command omitted id"
  | [ `String _ ] -> Error "adapter command id must contain 1 to 128 characters"
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
      Error ("adapter command " ^ name ^ " must contain 1 to 128 characters")
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
                              | Ok path, Ok _ when scalar_length path < 3 ->
                                  fail
                                    "adapter command path must contain at \
                                     least 3 characters"
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

let serve reader writer =
  let client = ref None in
  let relays : (string, relay) Hashtbl.t = Hashtbl.create 8 in
  let running = ref true in
  while !running do
    match read_command_line reader with
    | Eof -> running := false
    | Overlong ->
        emit writer
          (error_event
             (Convex.Protocol_error
                ("adapter command exceeds "
                ^ string_of_int max_command_bytes
                ^ " bytes")))
    | Line line -> (
        let json = try Some (J.from_string line) with _ -> None in
        match json with
        | None ->
            emit writer
              (error_event (Convex.Protocol_error "malformed adapter command"))
        | Some json -> (
            match parse_command json with
            | Error (id, message) ->
                emit writer (error_event ?id (Convex.Protocol_error message))
            | Ok (Hello id) ->
                emit writer
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
                | Error error -> emit writer (error_event ~id error)
                | Ok active -> (
                    let result =
                      match operation with
                      | "query" -> Convex.query active path args
                      | "mutation" -> Convex.mutation active path args
                      | _ -> Convex.action active path args
                    in
                    match result with
                    | Error error -> emit writer (error_event ~id error)
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
                        emit writer (`Assoc fields)))
            | Ok (Set_auth { id; token }) -> (
                match ensure_client client with
                | Error error -> emit writer (error_event ~id error)
                | Ok active -> (
                    match Convex.set_auth active token with
                    | Ok () -> emit writer (ack_event id)
                    | Error error -> emit writer (error_event ~id error)))
            | Ok (Subscribe { id; subscription_id; path; args }) -> (
                match ensure_client client with
                | Error error -> emit writer (error_event ~id error)
                | Ok active -> (
                    (match Hashtbl.find_opt relays subscription_id with
                    | Some old ->
                        stop_relay old;
                        Hashtbl.remove relays subscription_id
                    | None -> ());
                    match Convex.subscribe active path args with
                    | Error error -> emit writer (error_event ~id error)
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
                        start_relay writer relay;
                        emit writer (ack_event id)))
            | Ok (Unsubscribe { id; subscription_id }) ->
                (match Hashtbl.find_opt relays subscription_id with
                | Some relay ->
                    stop_relay relay;
                    Hashtbl.remove relays subscription_id
                | None -> ());
                emit writer (ack_event id)
            | Ok (Debug_disconnect id) -> (
                match ensure_client client with
                | Error error -> emit writer (error_event ~id error)
                | Ok active -> (
                    match Convex.debug_disconnect active with
                    | Ok () -> emit writer (ack_event id)
                    | Error error -> emit writer (error_event ~id error)))
            | Ok (Close id) ->
                Hashtbl.iter (fun _ relay -> stop_relay relay) relays;
                Hashtbl.clear relays;
                (match !client with
                | Some active -> Convex.close active
                | None -> ());
                emit writer
                  (`Assoc [ ("id", `String id); ("type", `String "closed") ]);
                running := false))
  done

let run ~input ~output =
  let writer = create_writer output in
  let thread = Thread.create (fun () -> writer_loop writer) () in
  serve (create_reader input) writer;
  stop_writer writer thread

(* Writing to a peer that has gone away has to be an error value this process
   can report, not a signal that ends it. OCaml leaves SIGPIPE at its default
   disposition, which terminates the process silently: no stderr, no exit code
   a controller can interpret, and none of the terminal-stream reporting above
   - which exists precisely to make a broken output stream visible - ever runs.
   Every descriptor this adapter writes to belongs to someone who may close it
   first, so the condition has to arrive as EPIPE. *)
let () = ignore (Sys.signal Sys.sigpipe Sys.Signal_ignore)

let () =
  match Sys.getenv_opt "ADAPTER_LISTEN" with
  | None -> run ~input:Unix.stdin ~output:Unix.stdout
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
      run ~input:client_socket ~output:client_socket
