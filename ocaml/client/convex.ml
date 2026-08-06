(*
   This file deliberately keeps the Convex-specific protocol in OCaml.  Unix
   sockets, ocaml-ssl, and Yojson are transport and representation helpers;
   no other Convex client is invoked by this implementation.
*)

module J = Yojson.Safe

type result = { value : J.t; logs : string list }

type error =
  | Function_error of {
      operation : string;
      message : string;
      data : J.t option;
      logs : string list;
    }
  | Protocol_error of string
  | Http_error of { operation : string; status_code : int; message : string }
  | Transport_error of { operation : string; message : string }
  | Closed

let error_name = function
  | Function_error _ -> "FunctionError"
  | Protocol_error _ -> "ProtocolError"
  | Http_error _ -> "HttpError"
  | Transport_error _ -> "TransportError"
  | Closed -> "Closed"

let error_message = function
  | Function_error { message; _ } -> message
  | Protocol_error message -> message
  | Http_error { operation; status_code; message } ->
      "HTTP " ^ operation ^ " returned " ^ string_of_int status_code ^ ": "
      ^ message
  | Transport_error { operation; message } -> operation ^ ": " ^ message
  | Closed -> "client is closed"

let error_data = function Function_error { data; _ } -> data | _ -> None
let error_logs = function Function_error { logs; _ } -> logs | _ -> []

let protect_error operation f =
  try f () with
  | Unix.Unix_error (e, fn, arg) ->
      Error
        (Transport_error
           {
             operation;
             message = fn ^ "(" ^ arg ^ "): " ^ Unix.error_message e;
           })
  | Failure message -> Error (Transport_error { operation; message })
  | Sys_error message -> Error (Transport_error { operation; message })

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match member name json with Some (`String value) -> Some value | _ -> None

let list_string_member name json =
  match member name json with
  | Some (`List values) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest -> collect (value :: acc) rest
        | _ ->
            Error (Protocol_error ("field " ^ name ^ " must contain strings"))
      in
      collect [] values
  | Some `Null | None -> Ok []
  | _ -> Error (Protocol_error ("field " ^ name ^ " must be an array"))

let response_logs json =
  match list_string_member "logLines" json with
  | Ok logs -> Ok logs
  | Error error -> Error error

let response_string name json =
  match member name json with
  | Some (`String value) -> Ok value
  | None -> Error (Protocol_error ("response omitted " ^ name))
  | Some _ -> Error (Protocol_error ("field " ^ name ^ " must be a string"))

(* Small URL parser sufficient for deployment URLs.  The root project passes
   URLs without credentials; rejecting credentials prevents accidental token
   leakage into the Host header. *)
type endpoint = { scheme : string; host : string; port : int; path : string }

let parse_endpoint raw =
  try
    let colon = String.index raw ':' in
    let scheme = String.lowercase_ascii (String.sub raw 0 colon) in
    if scheme <> "http" && scheme <> "https" then
      Error (Protocol_error "Convex URL must use http or https")
    else
      let after_scheme = colon + 3 in
      if
        String.length raw <= after_scheme
        || String.sub raw (colon + 1) 2 <> "//"
      then Error (Protocol_error "Convex URL must include //")
      else
        let rest =
          String.sub raw after_scheme (String.length raw - after_scheme)
        in
        let slash =
          match String.index_opt rest '/' with
          | Some value -> value
          | None -> String.length rest
        in
        let authority = String.sub rest 0 slash in
        if String.contains authority '@' then
          Error (Protocol_error "Convex URL must not include user information")
        else
          let host, port =
            match String.rindex_opt authority ':' with
            | Some index
              when not (String.contains (String.sub authority 0 index) ':') ->
                let host = String.sub authority 0 index in
                let port =
                  int_of_string
                    (String.sub authority (index + 1)
                       (String.length authority - index - 1))
                in
                (host, port)
            | _ -> (authority, if scheme = "https" then 443 else 80)
          in
          if host = "" then
            Error (Protocol_error "Convex URL must include a host")
          else
            let path =
              if slash = String.length rest then ""
              else String.sub rest slash (String.length rest - slash)
            in
            let path =
              if path = "" || path = "/" then ""
              else if path.[String.length path - 1] = '/' then
                String.sub path 0 (String.length path - 1)
              else path
            in
            Ok { scheme; host; port; path }
  with Not_found | Invalid_argument _ | Failure _ ->
    Error (Protocol_error "invalid Convex deployment URL")

type channel = {
  fd : Unix.file_descr;
  ssl : Ssl.socket option;
  mutable closed : bool;
}

exception Channel_closed
exception Read_timeout
exception Websocket_closed of string
exception Websocket_protocol of string

let close_channel channel =
  if not channel.closed then (
    channel.closed <- true;
    (match channel.ssl with
    | Some ssl -> ( try Ssl.shutdown ssl with _ -> ())
    | None -> ());
    try Unix.close channel.fd with _ -> ())

let wait_readable fd timeout =
  let ready, _, _ = Unix.select [ fd ] [] [] timeout in
  match ready with [] -> raise Read_timeout | _ -> ()

let read_some channel bytes offset length timeout =
  if channel.closed then raise Channel_closed;
  wait_readable channel.fd timeout;
  let count =
    match channel.ssl with
    | None -> Unix.read channel.fd bytes offset length
    | Some ssl -> Ssl.read ssl bytes offset length
  in
  if count = 0 then raise Channel_closed else count

let read_exact channel length timeout =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then bytes
    else loop (offset + read_some channel bytes offset (length - offset) timeout)
  in
  loop 0

let write_all channel bytes offset length =
  if channel.closed then raise Channel_closed;
  let rec loop position remaining =
    if remaining > 0 then
      let count =
        match channel.ssl with
        | None -> Unix.write channel.fd bytes position remaining
        | Some ssl -> Ssl.write ssl bytes position remaining
      in
      if count = 0 then raise Channel_closed
      else loop (position + count) (remaining - count)
  in
  loop offset length

let write_string channel string =
  let bytes = Bytes.of_string string in
  write_all channel bytes 0 (Bytes.length bytes)

let connect_tcp host port =
  let addresses =
    Unix.getaddrinfo host (string_of_int port)
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  let rec try_addresses = function
    | [] ->
        raise
          (Failure ("could not connect to " ^ host ^ ":" ^ string_of_int port))
    | address :: rest -> (
        let fd =
          Unix.socket address.Unix.ai_family address.Unix.ai_socktype
            address.Unix.ai_protocol
        in
        try
          Unix.connect fd address.Unix.ai_addr;
          fd
        with Unix.Unix_error _ ->
          Unix.close fd;
          try_addresses rest)
  in
  try_addresses addresses

let open_channel endpoint =
  let fd = connect_tcp endpoint.host endpoint.port in
  match endpoint.scheme with
  | "http" -> { fd; ssl = None; closed = false }
  | "https" -> (
      try
        Ssl.init ();
        let context = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
        Ssl.set_verify context [ Ssl.Verify_peer ] None;
        (try
           Ssl.load_verify_locations context
             "/etc/ssl/certs/ca-certificates.crt" ""
         with _ -> ());
        let ssl = Ssl.embed_socket fd context in
        (try Ssl.set_client_SNI_hostname ssl endpoint.host with _ -> ());
        Ssl.connect ssl;
        { fd; ssl = Some ssl; closed = false }
      with error ->
        Unix.close fd;
        raise error)
  | _ -> assert false

let read_line channel timeout =
  let buffer = Buffer.create 80 in
  let one = Bytes.create 1 in
  let rec loop () =
    let count = read_some channel one 0 1 timeout in
    if count <> 1 then raise Channel_closed;
    Buffer.add_char buffer (Bytes.get one 0);
    let length = Buffer.length buffer in
    if
      length >= 2
      && Buffer.nth buffer (length - 2) = '\r'
      && Buffer.nth buffer (length - 1) = '\n'
    then Buffer.contents buffer
    else if length > 8192 then
      raise (Failure "HTTP header line exceeds 8192 bytes")
    else loop ()
  in
  loop ()

let read_http_response channel =
  let status_line = read_line channel 30.0 in
  let status_code =
    try int_of_string (String.sub status_line 9 3)
    with _ -> raise (Failure "invalid HTTP status line")
  in
  let rec headers content_length chunked =
    let line = read_line channel 30.0 in
    if line = "\r\n" then (content_length, chunked)
    else
      match String.index_opt line ':' with
      | None -> headers content_length chunked
      | Some colon ->
          let key = String.lowercase_ascii (String.sub line 0 colon) in
          let value =
            String.trim
              (String.sub line (colon + 1) (String.length line - colon - 3))
          in
          if key = "content-length" then
            headers (Some (int_of_string value)) chunked
          else if
            key = "transfer-encoding"
            && String.lowercase_ascii value = "chunked"
          then headers content_length true
          else headers content_length chunked
  in
  let content_length, chunked = headers None false in
  let read_body () =
    match (content_length, chunked) with
    | Some length, _ when length <= 2 * 1024 * 1024 ->
        Bytes.to_string (read_exact channel length 30.0)
    | Some _, _ -> raise (Failure "HTTP response exceeds 2097152 bytes")
    | None, true ->
        let output = Buffer.create 256 in
        let rec chunks () =
          let line = read_line channel 30.0 in
          let size =
            int_of_string
              (String.trim (String.sub line 0 (String.length line - 2)))
          in
          if size = 0 then ignore (read_line channel 30.0)
          else (
            Buffer.add_string output
              (Bytes.to_string (read_exact channel size 30.0));
            ignore (read_line channel 30.0);
            chunks ())
        in
        chunks ();
        Buffer.contents output
    | None, false -> ""
  in
  (status_code, read_body ())

let http_call endpoint ~client_version ~auth_token operation path args =
  protect_error ("HTTP " ^ operation) (fun () ->
      if path = "" then raise (Failure "Convex function path is required");
      let channel = open_channel endpoint in
      Fun.protect
        ~finally:(fun () -> close_channel channel)
        (fun () ->
          let body =
            J.to_string
              (`Assoc
                 [
                   ("path", `String path);
                   ("args", args);
                   ("format", `String "json");
                 ])
          in
          let request =
            "POST " ^ endpoint.path ^ "/api/" ^ operation ^ " HTTP/1.1\r\n"
            ^ "Host: " ^ endpoint.host ^ "\r\n"
            ^ "Content-Type: application/json\r\nAccept: application/json\r\n"
            ^ "Convex-Client: " ^ client_version ^ "\r\n"
            ^ (match auth_token with
              | Some token when token <> "" ->
                  "Authorization: Bearer " ^ token ^ "\r\n"
              | _ -> "")
            ^ "Content-Length: "
            ^ string_of_int (String.length body)
            ^ "\r\nConnection: close\r\n\r\n" ^ body
          in
          write_string channel request;
          let status_code, response_body = read_http_response channel in
          let successful_status = status_code >= 200 && status_code < 300 in
          match try Ok (J.from_string response_body) with _ -> Error () with
          | Error () when not successful_status ->
              Error
                (Http_error
                   {
                     operation;
                     status_code;
                     message = "response body was not valid JSON";
                   })
          | Error () ->
              Error
                (Protocol_error
                   ("HTTP " ^ string_of_int status_code
                  ^ " response body was not valid JSON"))
          | Ok (`Assoc _ as response) -> (
              match response_string "status" response with
              | Error error -> Error error
              | Ok "error" -> (
                  (* Convex function failures use a non-2xx status such as 560.
                     Preserve their structured data, but never let a success
                     envelope override an unsuccessful HTTP status. *)
                  match
                    ( response_string "errorMessage" response,
                      response_logs response )
                  with
                  | Error error, _ | _, Error error -> Error error
                  | Ok message, Ok logs ->
                      let data =
                        match member "errorData" response with
                        | Some `Null | None -> None
                        | Some value -> Some value
                      in
                      Error (Function_error { operation; message; data; logs }))
              | Ok "success" when not successful_status ->
                  Error
                    (Http_error
                       {
                         operation;
                         status_code;
                         message =
                           "unsuccessful HTTP status carried a success response";
                       })
              | Ok "success" -> (
                  match (member "value" response, response_logs response) with
                  | None, _ ->
                      Error (Protocol_error "success response omitted value")
                  | _, Error error -> Error error
                  | Some value, Ok logs -> Ok { value; logs })
              | Ok status when not successful_status ->
                  Error
                    (Http_error
                       {
                         operation;
                         status_code;
                         message = "response had Convex status " ^ status;
                       })
              | Ok status ->
                  Error
                    (Protocol_error
                       ("HTTP " ^ string_of_int status_code
                      ^ " response has unknown status " ^ status)))
          | Ok _ when not successful_status ->
              Error
                (Http_error
                   {
                     operation;
                     status_code;
                     message = "response body was not a JSON object";
                   })
          | Ok _ ->
              Error
                (Protocol_error
                   ("HTTP " ^ string_of_int status_code
                  ^ " response body must be a JSON object"))))

let base64_chars =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64_encode bytes =
  let length = Bytes.length bytes in
  let output = Buffer.create ((length + 2) / 3 * 4) in
  let value index =
    if index < length then Char.code (Bytes.get bytes index) else 0
  in
  let rec loop index =
    if index < length then (
      let a, b, c = (value index, value (index + 1), value (index + 2)) in
      Buffer.add_char output base64_chars.[a lsr 2];
      Buffer.add_char output base64_chars.[((a land 3) lsl 4) lor (b lsr 4)];
      Buffer.add_char output
        (if index + 1 < length then
           base64_chars.[((b land 15) lsl 2) lor (c lsr 6)]
         else '=');
      Buffer.add_char output
        (if index + 2 < length then base64_chars.[c land 63] else '=');
      loop (index + 3))
  in
  loop 0;
  Buffer.contents output

let base64_value character =
  match String.index_opt base64_chars character with
  | Some value -> value
  | None -> -1

let base64_decode string =
  if String.length string mod 4 <> 0 then
    raise (Failure "invalid base64 length");
  let output = Buffer.create (String.length string / 4 * 3) in
  let rec loop index =
    if index < String.length string then (
      let a, b =
        (base64_value string.[index], base64_value string.[index + 1])
      in
      if a < 0 || b < 0 then raise (Failure "invalid base64 character");
      let c =
        if string.[index + 2] = '=' then 0 else base64_value string.[index + 2]
      in
      let d =
        if string.[index + 3] = '=' then 0 else base64_value string.[index + 3]
      in
      if c < 0 || d < 0 then raise (Failure "invalid base64 character");
      Buffer.add_char output (Char.chr ((a lsl 2) lor (b lsr 4)));
      if string.[index + 2] <> '=' then
        Buffer.add_char output (Char.chr (((b land 15) lsl 4) lor (c lsr 2)));
      if string.[index + 3] <> '=' then
        Buffer.add_char output (Char.chr (((c land 3) lsl 6) lor d));
      loop (index + 4))
  in
  loop 0;
  Bytes.of_string (Buffer.contents output)

let random_bytes length =
  let fd = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> read_exact { fd; ssl = None; closed = false } length 5.0)

type ws = {
  channel : channel;
  mutable fragment_opcode : int option;
  fragments : Buffer.t;
}

let ws_write_frame ws opcode payload =
  let length = String.length payload in
  let header_length =
    if length < 126 then 2 else if length <= 65535 then 4 else 10
  in
  let header = Bytes.create (header_length + 4) in
  Bytes.set header 0 (Char.chr (0x80 lor opcode));
  if length < 126 then Bytes.set header 1 (Char.chr (0x80 lor length))
  else if length <= 65535 then (
    Bytes.set header 1 (Char.chr 0xfe);
    Bytes.set header 2 (Char.chr (length lsr 8));
    Bytes.set header 3 (Char.chr (length land 255)))
  else (
    Bytes.set header 1 (Char.chr 0xff);
    let value = Int64.of_int length in
    for index = 0 to 7 do
      Bytes.set header (2 + index)
        (Char.chr
           (Int64.to_int
              (Int64.logand
                 (Int64.shift_right_logical value ((7 - index) * 8))
                 255L)))
    done);
  let mask_offset = header_length in
  let mask = random_bytes 4 in
  Bytes.blit mask 0 header mask_offset 4;
  let body = Bytes.of_string payload in
  for index = 0 to length - 1 do
    Bytes.set body index
      (Char.chr
         (Char.code (Bytes.get body index)
         lxor Char.code (Bytes.get mask (index mod 4))))
  done;
  write_all ws.channel header 0 (Bytes.length header);
  write_all ws.channel body 0 length

let ws_read_frame ws timeout =
  let header = read_exact ws.channel 2 timeout in
  let first, second =
    (Char.code (Bytes.get header 0), Char.code (Bytes.get header 1))
  in
  let fin = first land 0x80 <> 0 in
  let opcode = first land 0x0f in
  let masked = second land 0x80 <> 0 in
  let short_length = second land 0x7f in
  let length =
    if short_length < 126 then Int64.of_int short_length
    else if short_length = 126 then
      let bytes = read_exact ws.channel 2 timeout in
      Int64.of_int
        ((Char.code (Bytes.get bytes 0) lsl 8) lor Char.code (Bytes.get bytes 1))
    else
      let bytes = read_exact ws.channel 8 timeout in
      let value = ref 0L in
      for index = 0 to 7 do
        value :=
          Int64.logor
            (Int64.shift_left !value 8)
            (Int64.of_int (Char.code (Bytes.get bytes index)))
      done;
      if Int64.compare !value (Int64.of_int (2 * 1024 * 1024)) > 0 then
        raise (Websocket_protocol "WebSocket message exceeds 2097152 bytes");
      !value
  in
  if Int64.compare length (Int64.of_int (2 * 1024 * 1024)) > 0 then
    raise (Websocket_protocol "WebSocket message exceeds 2097152 bytes");
  let mask = if masked then Some (read_exact ws.channel 4 timeout) else None in
  let payload = read_exact ws.channel (Int64.to_int length) timeout in
  (match mask with
  | Some mask ->
      for index = 0 to Bytes.length payload - 1 do
        Bytes.set payload index
          (Char.chr
             (Char.code (Bytes.get payload index)
             lxor Char.code (Bytes.get mask (index mod 4))))
      done
  | None -> ());
  (fin, opcode, Bytes.to_string payload)

let ws_read_message ws =
  let rec loop () =
    let fin, opcode, payload = ws_read_frame ws 30.0 in
    if opcode = 8 then raise (Websocket_closed "server close")
    else if opcode = 9 then (
      ws_write_frame ws 10 payload;
      loop ())
    else if opcode = 10 then loop ()
    else if opcode = 0 then (
      match ws.fragment_opcode with
      | None -> raise (Websocket_protocol "unexpected WebSocket continuation")
      | Some _ ->
          Buffer.add_string ws.fragments payload;
          if fin then (
            let value = Buffer.contents ws.fragments in
            Buffer.clear ws.fragments;
            ws.fragment_opcode <- None;
            value)
          else loop ())
    else if opcode = 1 then
      if fin then payload
      else (
        Buffer.clear ws.fragments;
        Buffer.add_string ws.fragments payload;
        ws.fragment_opcode <- Some opcode;
        loop ())
    else raise (Websocket_protocol "unsupported WebSocket opcode")
  in
  loop ()

let websocket_connect endpoint ~client_version ~auth_token =
  let channel = open_channel endpoint in
  try
    let key = base64_encode (random_bytes 16) in
    let request =
      "GET " ^ endpoint.path ^ "/api/sync HTTP/1.1\r\nHost: " ^ endpoint.host
      ^ "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: "
      ^ key ^ "\r\nSec-WebSocket-Version: 13\r\nConvex-Client: "
      ^ client_version ^ "\r\n"
      ^ (match auth_token with
        | Some token when token <> "" ->
            "Authorization: Bearer " ^ token ^ "\r\n"
        | _ -> "")
      ^ "\r\n"
    in
    write_string channel request;
    let status, _ = read_http_response channel in
    if status <> 101 then
      raise
        (Failure ("WebSocket handshake returned HTTP " ^ string_of_int status));
    { channel; fragment_opcode = None; fragments = Buffer.create 256 }
  with error ->
    close_channel channel;
    raise error

type queued_update = update
and update = { value : J.t option; error : error option; logs : string list }

type subscription_state = {
  qid : int;
  path : string;
  args : J.t;
  mutex : Mutex.t;
  mutable queue : queued_update list;
  mutable queue_bytes : int;
  mutable closed : bool;
}

let max_queue_items = 16
let max_queue_bytes = 4 * 1024 * 1024

let update_size update =
  (match update.value with
  | None -> 0
  | Some value -> String.length (J.to_string value))
  +
  match update.error with
  | None -> 0
  | Some error -> String.length (error_message error)

let enqueue state update =
  Mutex.lock state.mutex;
  if not state.closed then (
    let update_bytes = update_size update in
    state.queue <- state.queue @ [ update ];
    state.queue_bytes <- state.queue_bytes + update_bytes;
    let rec trim () =
      if
        List.length state.queue > max_queue_items
        || state.queue_bytes > max_queue_bytes
      then (
        match state.queue with
        | [] -> ()
        | oldest :: rest ->
            state.queue <- rest;
            state.queue_bytes <- state.queue_bytes - update_size oldest;
            trim ())
      else ()
    in
    trim ());
  Mutex.unlock state.mutex

let dequeue state timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    Mutex.lock state.mutex;
    match state.queue with
    | update :: rest ->
        state.queue <- rest;
        state.queue_bytes <- state.queue_bytes - update_size update;
        Mutex.unlock state.mutex;
        Some update
    | [] when state.closed ->
        Mutex.unlock state.mutex;
        None
    | [] ->
        Mutex.unlock state.mutex;
        if timeout >= 0.0 && Unix.gettimeofday () >= deadline then None
        else (
          Thread.delay 0.02;
          loop ())
  in
  loop ()

type live_command =
  | Add of subscription_state
  | Remove of subscription_state
  | Disconnect of (unit, error) Stdlib.result option ref
  | Stop

type live_manager = {
  endpoint : endpoint;
  client_version : string;
  mutable auth_token : string option;
  commands : live_command Queue.t;
  command_mutex : Mutex.t;
  wake_read : Unix.file_descr;
  wake_write : Unix.file_descr;
  mutable closed : bool;
  mutable next_qid : int;
  owner : Thread.t;
}

type client = {
  endpoint : endpoint;
  client_version : string;
  mutex : Mutex.t;
  mutable auth_token : string option;
  mutable closed : bool;
  live : live_manager;
}

type subscription = { manager : live_manager; state : subscription_state }

let timestamp_bytes value =
  try
    let bytes = base64_decode value in
    if Bytes.length bytes <> 8 then None else Some bytes
  with _ -> None

let compare_timestamps left right =
  match (timestamp_bytes left, timestamp_bytes right) with
  | Some left, Some right ->
      let rec compare index =
        if index < 0 then 0
        else if Bytes.get left index > Bytes.get right index then 1
        else if Bytes.get left index < Bytes.get right index then -1
        else compare (index - 1)
      in
      Ok (compare 7)
  | _ -> Error (Protocol_error "timestamp must be base64 encoded uint64")

let zero_version () =
  `Assoc
    [
      ("querySet", `Int 0); ("identity", `Int 0); ("ts", `String "AAAAAAAAAAA=");
    ]

let equal_json left right = J.equal left right

let assoc name json =
  match member name json with
  | Some value -> value
  | None -> raise (Failure ("missing field " ^ name))

let int_member name json =
  match assoc name json with
  | `Int value -> value
  | `Intlit value -> int_of_string value
  | _ -> raise (Failure (name ^ " must be an integer"))

let session_id () =
  (* The sync protocol parses this field as a UUID, not as an arbitrary
     opaque session token.  Keep the UUID version and variant bits canonical. *)
  let raw = random_bytes 16 in
  Bytes.set raw 6 (Char.chr (Char.code (Bytes.get raw 6) land 0x0f lor 0x40));
  Bytes.set raw 8 (Char.chr (Char.code (Bytes.get raw 8) land 0x3f lor 0x80));
  let hex = "0123456789abcdef" in
  let encoded = Bytes.create 36 in
  let output = ref 0 in
  for index = 0 to 15 do
    if index = 4 || index = 6 || index = 8 || index = 10 then (
      Bytes.set encoded !output '-';
      incr output);
    let value = Char.code (Bytes.get raw index) in
    Bytes.set encoded !output hex.[value lsr 4];
    incr output;
    Bytes.set encoded !output hex.[value land 0x0f];
    incr output
  done;
  Bytes.to_string encoded

let command (manager : live_manager) command =
  Mutex.lock manager.command_mutex;
  Queue.push command manager.commands;
  Mutex.unlock manager.command_mutex;
  try ignore (Unix.write manager.wake_write (Bytes.of_string "x") 0 1)
  with _ -> ()

let json_send ws json = ws_write_frame ws 1 (J.to_string json)

let modify_message base new_version modifications =
  `Assoc
    [
      ("type", `String "ModifyQuerySet");
      ("baseVersion", `Int base);
      ("newVersion", `Int new_version);
      ("modifications", `List modifications);
    ]

let add_modification state =
  `Assoc
    [
      ("type", `String "Add");
      ("queryId", `Int state.qid);
      ("udfPath", `String state.path);
      ("args", `List [ state.args ]);
    ]

let remove_modification state =
  `Assoc [ ("type", `String "Remove"); ("queryId", `Int state.qid) ]

let live_owner (manager : live_manager) =
  let active : (int, subscription_state) Hashtbl.t = Hashtbl.create 8 in
  let last_delivered : (int, queued_update) Hashtbl.t = Hashtbl.create 8 in
  let awaiting : (int, bool) Hashtbl.t = Hashtbl.create 8 in
  let connection = ref None in
  let query_set_version = ref 0 in
  let remote_version = ref (zero_version ()) in
  let connection_count = ref 0 in
  let last_close_reason = ref "InitialConnect" in
  let max_timestamp : string option ref = ref None in
  let reconnect_at = ref None in
  let backoff = ref 0.1 in
  let set_reconnect delay =
    reconnect_at := Some (Unix.gettimeofday () +. delay)
  in
  let close_connection reason schedule =
    (match !connection with
    | Some ws ->
        close_channel ws.channel;
        connection := None;
        incr connection_count
    | None -> ());
    last_close_reason := reason;
    query_set_version := 0;
    remote_version := zero_version ();
    if schedule && Hashtbl.length active > 0 then (
      set_reconnect !backoff;
      backoff := min 15.0 (!backoff *. 2.0))
    else reconnect_at := None
  in
  let deliver qid update =
    match Hashtbl.find_opt active qid with
    | Some state -> enqueue state update
    | None -> ()
  in
  let protocol_failure error =
    Hashtbl.iter
      (fun qid _ ->
        deliver qid
          { value = None; error = Some error; logs = error_logs error })
      active
  in
  let connect () =
    try
      let ws =
        websocket_connect manager.endpoint
          ~client_version:manager.client_version ~auth_token:manager.auth_token
      in
      connection := Some ws;
      remote_version := zero_version ();
      query_set_version := 0;
      let connect_fields =
        [
          ("type", `String "Connect");
          ("sessionId", `String (session_id ()));
          ("connectionCount", `Int !connection_count);
          ("lastCloseReason", `String !last_close_reason);
          ("clientTs", `Int 0);
        ]
      in
      let connect_fields =
        match !max_timestamp with
        | None -> connect_fields
        | Some value ->
            ("maxObservedTimestamp", `String value) :: connect_fields
      in
      let connect_message = `Assoc connect_fields in
      json_send ws connect_message;
      let states =
        Hashtbl.fold (fun _ state acc -> state :: acc) active []
        |> List.sort (fun left right -> compare left.qid right.qid)
      in
      if states <> [] then (
        List.iter
          (fun state ->
            if Hashtbl.mem last_delivered state.qid then
              Hashtbl.replace awaiting state.qid true)
          states;
        json_send ws (modify_message 0 1 (List.map add_modification states));
        query_set_version := 1);
      reconnect_at := None
    with error ->
      last_close_reason := Printexc.to_string error;
      incr connection_count;
      close_connection !last_close_reason true
  in
  let send_modify modification =
    match !connection with
    | None -> set_reconnect 0.0
    | Some ws -> (
        try
          json_send ws
            (modify_message !query_set_version (!query_set_version + 1)
               [ modification ]);
          query_set_version := !query_set_version + 1
        with error -> close_connection (Printexc.to_string error) true)
  in
  let handle_transition json =
    let start_version, end_version =
      (assoc "startVersion" json, assoc "endVersion" json)
    in
    if not (equal_json start_version !remote_version) then
      raise (Failure "Transition start version does not match local version");
    let changed = Hashtbl.create 4 in
    let modifications =
      match assoc "modifications" json with
      | `List values -> values
      | _ -> raise (Failure "Transition modifications must be an array")
    in
    List.iter
      (fun modification ->
        let qid = int_member "queryId" modification in
        match string_member "type" modification with
        | Some "QueryUpdated" ->
            let value = assoc "value" modification in
            let update =
              {
                value = Some value;
                error = None;
                logs =
                  (match list_string_member "logLines" modification with
                  | Ok values -> values
                  | Error _ -> []);
              }
            in
            let previous = Hashtbl.find_opt last_delivered qid in
            Hashtbl.replace last_delivered qid update;
            if Hashtbl.mem awaiting qid then (
              Hashtbl.remove awaiting qid;
              match previous with
              | Some previous
                when previous.value = update.value && previous.error = None ->
                  ()
              | _ -> Hashtbl.replace changed qid update)
            else Hashtbl.replace changed qid update
        | Some "QueryFailed" ->
            let message =
              match string_member "errorMessage" modification with
              | Some value -> value
              | None -> "Convex query failed"
            in
            let data =
              match member "errorData" modification with
              | Some `Null | None -> None
              | Some value -> Some value
            in
            let update =
              {
                value = None;
                error =
                  Some
                    (Function_error
                       {
                         operation = "query";
                         message;
                         data;
                         logs =
                           (match
                              list_string_member "logLines" modification
                            with
                           | Ok values -> values
                           | Error _ -> []);
                       });
                logs =
                  (match list_string_member "logLines" modification with
                  | Ok values -> values
                  | Error _ -> []);
              }
            in
            Hashtbl.remove awaiting qid;
            Hashtbl.replace last_delivered qid update;
            Hashtbl.replace changed qid update
        | Some "QueryRemoved" ->
            Hashtbl.remove last_delivered qid;
            Hashtbl.remove awaiting qid
        | Some other ->
            raise (Failure ("unknown Transition modification " ^ other))
        | None -> raise (Failure "Transition modification omitted type"))
      modifications;
    remote_version := end_version;
    let timestamp =
      match string_member "ts" end_version with
      | Some value -> value
      | None -> raise (Failure "Transition endVersion omitted ts")
    in
    (match !max_timestamp with
    | None -> max_timestamp := Some timestamp
    | Some previous -> (
        match compare_timestamps timestamp previous with
        | Ok comparison when comparison > 0 -> max_timestamp := Some timestamp
        | Ok _ -> ()
        | Error _ as error ->
            raise
              (Failure
                 (error_message
                    (match error with
                    | Error value -> value
                    | Ok _ -> assert false)))));
    Hashtbl.iter (fun qid update -> deliver qid update) changed;
    backoff := 0.1
  in
  let handle_message message =
    match string_member "type" message with
    | Some "Transition" -> handle_transition message
    | Some "Ping" -> ()
    | Some "TransitionChunk" ->
        raise (Failure "TransitionChunk assembly is not implemented")
    | Some "FatalError" | Some "AuthError" ->
        raise
          (Failure
             (match string_member "error" message with
             | Some value -> value
             | None -> "Convex sync server error"))
    | Some "MutationResponse" | Some "ActionResponse" -> ()
    | Some other -> raise (Failure ("unknown server message " ^ other))
    | None -> raise (Failure "server message omitted type")
  in
  let drain_commands () =
    let commands = ref [] in
    Mutex.lock manager.command_mutex;
    while not (Queue.is_empty manager.commands) do
      commands := Queue.pop manager.commands :: !commands
    done;
    Mutex.unlock manager.command_mutex;
    List.rev !commands
  in
  let rec loop () =
    let timeout =
      match !reconnect_at with
      | None -> 30.0
      | Some at -> max 0.0 (at -. Unix.gettimeofday ())
    in
    let descriptors =
      manager.wake_read
      :: (match !connection with Some ws -> [ ws.channel.fd ] | None -> [])
    in
    let ready, _, _ = Unix.select descriptors [] [] timeout in
    if List.mem manager.wake_read ready then (
      ignore
        (try Unix.read manager.wake_read (Bytes.create 64) 0 64 with _ -> 0);
      List.iter
        (function
          | Add state -> (
              Hashtbl.replace active state.qid state;
              match !connection with
              | None -> set_reconnect 0.0
              | Some _ -> send_modify (add_modification state))
          | Remove state ->
              Hashtbl.remove active state.qid;
              Hashtbl.remove last_delivered state.qid;
              Hashtbl.remove awaiting state.qid;
              (match !connection with
              | Some _ -> send_modify (remove_modification state)
              | None -> ());
              Mutex.lock state.mutex;
              state.closed <- true;
              Mutex.unlock state.mutex
          | Disconnect reply ->
              if !connection = None then
                reply :=
                  Some
                    (Error
                       (Transport_error
                          {
                            operation = "live disconnect";
                            message = "WebSocket is not connected";
                          }))
              else (
                close_connection "DebugDisconnect" true;
                reply := Some (Ok ()))
          | Stop ->
              close_connection "ClientClosed" false;
              Hashtbl.iter
                (fun (_ : int) (state : subscription_state) ->
                  Mutex.lock state.mutex;
                  state.closed <- true;
                  Mutex.unlock state.mutex)
                active;
              manager.closed <- true)
        (drain_commands ());
      if manager.closed then () else loop ())
    else (
      (match !reconnect_at with
      | Some at when at <= Unix.gettimeofday () && !connection = None ->
          connect ()
      | _ -> ());
      match !connection with
      | Some ws when List.mem ws.channel.fd ready ->
          (try handle_message (J.from_string (ws_read_message ws))
           with error ->
             let message = Printexc.to_string error in
             protocol_failure (Protocol_error message);
             close_connection message true);
          if not manager.closed then loop ()
      | _ -> if not manager.closed then loop ())
  in
  loop ()

let create raw_url =
  match parse_endpoint raw_url with
  | Error error -> Error error
  | Ok endpoint ->
      let wake_read, wake_write = Unix.pipe () in
      let manager : live_manager =
        {
          endpoint;
          client_version = "ocaml-0.1.0";
          auth_token = None;
          commands = Queue.create ();
          command_mutex = Mutex.create ();
          wake_read;
          wake_write;
          closed = false;
          next_qid = 0;
          owner = Obj.magic 0;
        }
      in
      let owner = Thread.create (fun () -> live_owner manager) () in
      let manager = { manager with owner } in
      Ok
        {
          endpoint;
          client_version = "ocaml-0.1.0";
          mutex = Mutex.create ();
          auth_token = None;
          closed = false;
          live = manager;
        }

let with_client (client : client) _operation f =
  Mutex.lock client.mutex;
  let closed = client.closed in
  let token = client.auth_token in
  Mutex.unlock client.mutex;
  if closed then Error Closed else f token

let set_auth client token =
  Mutex.lock client.mutex;
  if client.closed then (
    Mutex.unlock client.mutex;
    Error Closed)
  else (
    client.auth_token <- (if token = "" then None else Some token);
    client.live.auth_token <- (if token = "" then None else Some token);
    Mutex.unlock client.mutex;
    Ok ())

let call client operation path args =
  with_client client operation (fun token ->
      http_call client.endpoint ~client_version:client.client_version
        ~auth_token:token operation path args)

let query client path args = call client "query" path args
let mutation client path args = call client "mutation" path args
let action client path args = call client "action" path args

let subscribe (client : client) path args =
  with_client client "subscribe" (fun _ ->
      if path = "" then
        Error (Protocol_error "Convex function path is required")
      else (
        Mutex.lock client.live.command_mutex;
        let qid = client.live.next_qid in
        client.live.next_qid <- client.live.next_qid + 1;
        Mutex.unlock client.live.command_mutex;
        let state =
          {
            qid;
            path;
            args;
            mutex = Mutex.create ();
            queue = [];
            queue_bytes = 0;
            closed = false;
          }
        in
        command client.live (Add state);
        Ok { manager = client.live; state }))

let subscription_next subscription timeout =
  if timeout < 0.0 then
    match dequeue subscription.state (-1.0) with
    | None -> Ok None
    | Some update -> Ok (Some update)
  else Ok (dequeue subscription.state timeout)

let unsubscribe subscription =
  command subscription.manager (Remove subscription.state);
  Ok ()

let debug_disconnect client =
  with_client client "live disconnect" (fun _ ->
      let result = ref None in
      command client.live (Disconnect result);
      let deadline = Unix.gettimeofday () +. 10.0 in
      let rec wait () =
        match !result with
        | Some value -> value
        | None when Unix.gettimeofday () < deadline ->
            Thread.delay 0.01;
            wait ()
        | None ->
            Error
              (Transport_error
                 {
                   operation = "live disconnect";
                   message = "timed out waiting for socket owner";
                 })
      in
      wait ())

let close client =
  Mutex.lock client.mutex;
  if not client.closed then (
    client.closed <- true;
    command client.live Stop;
    Mutex.unlock client.mutex;
    Thread.join client.live.owner;
    close_channel { fd = client.live.wake_read; ssl = None; closed = false };
    close_channel { fd = client.live.wake_write; ssl = None; closed = false })
  else Mutex.unlock client.mutex

let parse_integral_int64 json =
  let parse_decimal text =
    let text = String.trim text in
    if text = "" || String.contains text 'e' || String.contains text 'E' then
      Error "count must be a finite decimal number"
    else
      let sign, body =
        if text.[0] = '-' then (-1, String.sub text 1 (String.length text - 1))
        else (1, text)
      in
      let before, after =
        match String.index_opt body '.' with
        | Some index ->
            ( String.sub body 0 index,
              String.sub body (index + 1) (String.length body - index - 1) )
        | None -> (body, "")
      in
      let digits = before ^ after in
      if
        digits = ""
        || String.exists (fun char -> char < '0' || char > '9') digits
        || String.exists (fun char -> char <> '0') after
      then Error "count must be mathematically integral"
      else
        try
          let value =
            Int64.of_string ((if sign < 0 then "-" else "") ^ digits)
          in
          Ok value
        with _ -> Error "count is outside the int64 range"
  in
  match json with
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value -> parse_decimal value
  | `Float value when not (Float.is_finite value) ->
      Error "count must be a finite JSON number"
  | `Float value when Float.floor value <> value ->
      Error "count must be mathematically integral"
  | `Float value
    when value >= 9223372036854775808.0 || value < -9223372036854775808.0 ->
      Error "count is outside the int64 range"
  | `Float value -> Ok (Int64.of_float value)
  | `String _ -> Error "count must be a JSON number"
  | _ -> Error "count must be a finite JSON number"
