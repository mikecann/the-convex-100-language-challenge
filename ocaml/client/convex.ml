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

exception Channel_closed
exception Read_timeout
exception Read_interrupted
exception Http_protocol of string
exception Websocket_closed of string
exception Websocket_protocol of string

(* The socket owner reports a failed frame or handshake by turning the escaping
   exception into a ProtocolError message with [Printexc.to_string]. Without
   these printers a subscriber would receive the OCaml constructor spelling
   instead of the protocol rule that was actually broken. *)
let () =
  Printexc.register_printer (function
    | Http_protocol message -> Some message
    | Websocket_protocol message -> Some message
    | Websocket_closed reason -> Some ("WebSocket closed: " ^ reason)
    | _ -> None)

(* Convex strings, the sync protocol, and the adapter schema all count Unicode
   characters rather than bytes, and RFC 6455 requires text frames and close
   reasons to be well-formed UTF-8. This returns the scalar count of a valid
   encoding and [None] for anything a conforming decoder must reject:
   overlong forms, surrogate halves, and scalars above U+10FFFF. *)
let utf8_scalar_count value =
  let length = String.length value in
  let byte index = Char.code (String.unsafe_get value index) in
  let continuation index = index < length && byte index land 0xc0 = 0x80 in
  let rec scan index count =
    if index >= length then Some count
    else
      let first = byte index in
      if first < 0x80 then scan (index + 1) (count + 1)
      else if first < 0xc2 then
        (* 0x80-0xbf is a stray continuation byte and 0xc0-0xc1 can only ever
           be an overlong encoding of an ASCII scalar. *)
        None
      else if first < 0xe0 then
        if continuation (index + 1) then scan (index + 2) (count + 1) else None
      else if first < 0xf0 then
        if continuation (index + 1) && continuation (index + 2) then
          let scalar =
            ((first land 0x0f) lsl 12)
            lor ((byte (index + 1) land 0x3f) lsl 6)
            lor (byte (index + 2) land 0x3f)
          in
          if scalar < 0x800 || (scalar >= 0xd800 && scalar <= 0xdfff) then None
          else scan (index + 3) (count + 1)
        else None
      else if first < 0xf5 then
        if
          continuation (index + 1)
          && continuation (index + 2)
          && continuation (index + 3)
        then
          let scalar =
            ((first land 0x07) lsl 18)
            lor ((byte (index + 1) land 0x3f) lsl 12)
            lor ((byte (index + 2) land 0x3f) lsl 6)
            lor (byte (index + 3) land 0x3f)
          in
          if scalar < 0x10000 || scalar > 0x10ffff then None
          else scan (index + 4) (count + 1)
        else None
      else None
  in
  scan 0 0

let valid_utf8 value = utf8_scalar_count value <> None

(* OCaml 5.2's Unix module does not expose clock_gettime. This tiny libc stub
   gives every HTTP operation a clock that cannot jump when wall time changes. *)
external monotonic_now : unit -> float = "convex_monotonic_now"

let deadline_after seconds = monotonic_now () +. seconds

let remaining_until deadline =
  let remaining = deadline -. monotonic_now () in
  if remaining <= 0.0 then raise Read_timeout else remaining

let protect_error operation f =
  try f () with
  | Http_protocol message -> Error (Protocol_error message)
  | Channel_closed ->
      Error
        (Transport_error
           {
             operation;
             message = "connection closed before the response completed";
           })
  | Read_timeout ->
      Error
        (Transport_error
           { operation; message = "timed out while waiting for the response" })
  | Unix.Unix_error (e, fn, arg) ->
      Error
        (Transport_error
           {
             operation;
             message = fn ^ "(" ^ arg ^ "): " ^ Unix.error_message e;
           })
  | Ssl.Connection_error _ ->
      Error (Transport_error { operation; message = "TLS connection failed" })
  | Ssl.Read_error _ ->
      Error (Transport_error { operation; message = "TLS read failed" })
  | Ssl.Write_error _ ->
      Error (Transport_error { operation; message = "TLS write failed" })
  | Ssl.Verify_error _ ->
      Error
        (Transport_error
           { operation; message = "TLS certificate verification failed" })
  | Ssl.Invalid_socket ->
      Error (Transport_error { operation; message = "invalid TLS socket" })
  | Ssl.Method_error | Ssl.Context_error | Ssl.Handler_error ->
      Error
        (Transport_error
           { operation; message = "TLS transport initialization failed" })
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
  | None -> Ok []
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

let parse_url raw =
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

(* The host and path reach the request line and the Host header verbatim, so a
   space or control character in the URL would split the HTTP request. *)
let printable_ascii raw =
  let printable char = Char.code char > 0x20 && Char.code char < 0x7f in
  String.for_all printable raw

let parse_endpoint raw =
  if not (printable_ascii raw) then
    Error (Protocol_error "Convex URL must not contain control characters")
  else parse_url raw

type channel = {
  fd : Unix.file_descr;
  ssl : Ssl.socket option;
  mutable closed : bool;
  mutable nonblocking : bool;
}

let close_channel channel =
  if not channel.closed then (
    channel.closed <- true;
    (match channel.ssl with
    | Some ssl -> ( try Ssl.shutdown ssl with _ -> ())
    | None -> ());
    try Unix.close channel.fd with _ -> ())

let wait_for_io_until ?interrupt ~readable ~writable fd deadline =
  let reads = if readable then [ fd ] else [] in
  let reads =
    match interrupt with Some value -> value :: reads | None -> reads
  in
  let writes = if writable then [ fd ] else [] in
  let rec select () =
    try Unix.select reads writes [] (remaining_until deadline)
    with Unix.Unix_error (Unix.EINTR, _, _) -> select ()
  in
  let ready_reads, ready_writes, _ = select () in
  (match interrupt with
  | Some value when List.mem value ready_reads -> raise Read_interrupted
  | _ -> ());
  ignore (remaining_until deadline);
  if
    ((not readable) || not (List.mem fd ready_reads))
    && ((not writable) || not (List.mem fd ready_writes))
  then raise Read_timeout

let wait_readable_until ?interrupt fd deadline =
  wait_for_io_until ?interrupt ~readable:true ~writable:false fd deadline

let wait_writable_until ?interrupt fd deadline =
  wait_for_io_until ?interrupt ~readable:false ~writable:true fd deadline

let read_some_until ?interrupt channel bytes offset length deadline =
  if channel.closed then raise Channel_closed;
  let rec read_nonblocking () =
    ignore (remaining_until deadline);
    try
      match channel.ssl with
      | None -> Unix.read channel.fd bytes offset length
      | Some ssl -> Ssl.read ssl bytes offset length
    with
    (* A clean TLS close_notify is end of stream, not a transport failure.
       Report it exactly like a plain-socket EOF. *)
    | Ssl.Read_error Ssl.Error_zero_return -> raise Channel_closed
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
    | Ssl.Read_error Ssl.Error_want_read ->
        wait_readable_until ?interrupt channel.fd deadline;
        read_nonblocking ()
    | Ssl.Read_error Ssl.Error_want_write ->
        wait_writable_until ?interrupt channel.fd deadline;
        read_nonblocking ()
  in
  let count =
    if channel.nonblocking then read_nonblocking ()
    else (
      wait_readable_until ?interrupt channel.fd deadline;
      match channel.ssl with
      | None -> Unix.read channel.fd bytes offset length
      | Some ssl -> Ssl.read ssl bytes offset length)
  in
  if count = 0 then raise Channel_closed else count

let read_some ?interrupt channel bytes offset length timeout =
  read_some_until ?interrupt channel bytes offset length
    (deadline_after timeout)

let read_exact_until ?interrupt channel length deadline =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then bytes
    else
      loop
        (offset
        + read_some_until ?interrupt channel bytes offset (length - offset)
            deadline)
  in
  loop 0

let read_exact ?interrupt channel length timeout =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then bytes
    else
      loop
        (offset
        + read_some ?interrupt channel bytes offset (length - offset) timeout)
  in
  loop 0

let write_all_until ?interrupt channel bytes offset length deadline =
  if channel.closed then raise Channel_closed;
  let rec write_nonblocking position remaining_length =
    ignore (remaining_until deadline);
    try
      match channel.ssl with
      | None -> Unix.write channel.fd bytes position remaining_length
      | Some ssl -> Ssl.write ssl bytes position remaining_length
    with
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
    | Ssl.Write_error Ssl.Error_want_write ->
        wait_writable_until ?interrupt channel.fd deadline;
        write_nonblocking position remaining_length
    | Ssl.Write_error Ssl.Error_want_read ->
        wait_readable_until ?interrupt channel.fd deadline;
        write_nonblocking position remaining_length
  in
  let rec loop position remaining =
    if remaining > 0 then
      let count =
        if channel.nonblocking then write_nonblocking position remaining
        else
          match channel.ssl with
          | None -> Unix.write channel.fd bytes position remaining
          | Some ssl -> Ssl.write ssl bytes position remaining
      in
      if count = 0 then raise Channel_closed
      else loop (position + count) (remaining - count)
  in
  loop offset length

let write_all ?interrupt channel bytes offset length =
  write_all_until ?interrupt channel bytes offset length (deadline_after 30.0)

let write_string_until ?interrupt channel string deadline =
  let bytes = Bytes.of_string string in
  write_all_until ?interrupt channel bytes 0 (Bytes.length bytes) deadline

let resolve_tcp_until ?interrupt host port deadline =
  let ready_read, ready_write = Unix.pipe () in
  let mutex = Mutex.create () in
  let result = ref None in
  ignore
    (Thread.create
       (fun () ->
         let resolved =
           try
             Ok
               (Unix.getaddrinfo host (string_of_int port)
                  [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ])
           with error -> Error error
         in
         Mutex.lock mutex;
         result := Some resolved;
         Mutex.unlock mutex;
         (try ignore (Unix.write ready_write (Bytes.of_string "x") 0 1)
          with _ -> ());
         Unix.close ready_write)
       ());
  Fun.protect
    ~finally:(fun () -> Unix.close ready_read)
    (fun () ->
      wait_readable_until ?interrupt ready_read deadline;
      ignore (Unix.read ready_read (Bytes.create 1) 0 1);
      Mutex.lock mutex;
      let resolved = !result in
      Mutex.unlock mutex;
      match resolved with
      | Some (Ok addresses) -> addresses
      | Some (Error error) -> raise error
      | None -> raise Channel_closed)

let connect_address_until ?interrupt address deadline =
  ignore (remaining_until deadline);
  let fd =
    Unix.socket address.Unix.ai_family address.Unix.ai_socktype
      address.Unix.ai_protocol
  in
  Unix.set_nonblock fd;
  try
    (try Unix.connect fd address.Unix.ai_addr
     with
     | Unix.Unix_error
         ((Unix.EINPROGRESS | Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
     -> (
       wait_writable_until ?interrupt fd deadline;
       match Unix.getsockopt_error fd with
       | None -> ()
       | Some error -> raise (Unix.Unix_error (error, "connect", ""))));
    fd
  with error ->
    Unix.close fd;
    raise error

(* Every connection attempt is bounded, so DNS, connect, and the TLS handshake
   can never outlive the operation that asked for them. *)
let connect_tcp ?interrupt ~deadline host port =
  let addresses = resolve_tcp_until ?interrupt host port deadline in
  let rec try_addresses = function
    | [] ->
        raise
          (Failure ("could not connect to " ^ host ^ ":" ^ string_of_int port))
    | address :: rest -> (
        try connect_address_until ?interrupt address deadline
        with Unix.Unix_error _ -> try_addresses rest)
  in
  try_addresses addresses

let tls_connect_until ?interrupt ssl fd deadline =
  let rec connect () =
    ignore (remaining_until deadline);
    try Ssl.connect ssl with
    | Ssl.Connection_error Ssl.Error_want_read ->
        wait_readable_until ?interrupt fd deadline;
        connect ()
    | Ssl.Connection_error (Ssl.Error_want_write | Ssl.Error_want_connect) ->
        wait_writable_until ?interrupt fd deadline;
        connect ()
  in
  connect ()

let open_channel ?interrupt ~deadline endpoint =
  let fd = connect_tcp ?interrupt ~deadline endpoint.host endpoint.port in
  match endpoint.scheme with
  | "http" -> { fd; ssl = None; closed = false; nonblocking = true }
  | "https" -> (
      try
        Ssl.init ();
        let context = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
        Ssl.set_verify context [ Ssl.Verify_peer ] None;
        (* Prefer the distribution CA bundle and fall back to OpenSSL's own
           search paths. With neither store the peer stays untrusted, so a
           missing bundle fails the connection instead of skipping checks. *)
        (try
           Ssl.load_verify_locations context
             "/etc/ssl/certs/ca-certificates.crt" ""
         with _ -> ignore (Ssl.set_default_verify_paths context));
        let ssl = Ssl.embed_socket fd context in
        (* Verify_peer only proves the chain is trusted by someone. Binding the
           expected name makes OpenSSL also reject a valid certificate that was
           issued for a different host. *)
        Ssl.set_host ssl endpoint.host;
        (try Ssl.set_client_SNI_hostname ssl endpoint.host with _ -> ());
        tls_connect_until ?interrupt ssl fd deadline;
        { fd; ssl = Some ssl; closed = false; nonblocking = true }
      with error ->
        Unix.close fd;
        raise error)
  | _ -> assert false

(* Live gives each protocol operation its own duration. HTTP threads a single
   operation-wide deadline through every [_until] call below, so DNS, connect,
   TLS, the request, the status line, the headers, the body, and any trailers
   all share one budget instead of restarting the clock per step. *)
let read_line_until ?interrupt channel deadline =
  let buffer = Buffer.create 80 in
  let one = Bytes.create 1 in
  let rec loop () =
    let count = read_some_until ?interrupt channel one 0 1 deadline in
    if count <> 1 then raise Channel_closed;
    Buffer.add_char buffer (Bytes.get one 0);
    let length = Buffer.length buffer in
    if
      length >= 2
      && Buffer.nth buffer (length - 2) = '\r'
      && Buffer.nth buffer (length - 1) = '\n'
    then Buffer.contents buffer
    else if length > 8192 then
      raise (Http_protocol "HTTP header line exceeds 8192 bytes")
    else loop ()
  in
  loop ()

let max_http_body = 2 * 1024 * 1024
let max_http_header_lines = 128
let max_http_trailer_lines = 64

(* Content-Length is a plain decimal count. [int_of_string] would also accept
   "0x20", "1_0", and "+5", so the digits are checked before conversion. *)
let parse_content_length value =
  let digit char = char >= '0' && char <= '9' in
  if value = "" || not (String.for_all digit value) then
    raise (Http_protocol "invalid HTTP Content-Length header")
  else
    try int_of_string value
    with _ -> raise (Http_protocol "invalid HTTP Content-Length header")

let parse_chunk_size line =
  let text = String.trim (String.sub line 0 (String.length line - 2)) in
  let text =
    match String.index_opt text ';' with
    | Some index -> String.sub text 0 index
    | None -> text
  in
  let text = String.trim text in
  let hex char =
    (char >= '0' && char <= '9')
    || (char >= 'a' && char <= 'f')
    || (char >= 'A' && char <= 'F')
  in
  (* Eight hex digits cover every chunk this client accepts and stay far below
     the OCaml int range. A longer literal would wrap silently to a small
     positive size and leave the parser reading the next chunk's bytes. *)
  if text = "" || String.length text > 8 || not (String.for_all hex text) then
    raise (Http_protocol "invalid HTTP chunk size")
  else int_of_string ("0x" ^ text)

(* RFC 7230 field names are tokens. A line with no colon, an empty or padded
   name, or a non-token character is not a header this client may quietly
   ignore: it is evidence that something other than the deployment framed this
   response, and the framing headers it carries can no longer be trusted. *)
let http_token_char char =
  match char with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`'
  | '|' | '~' ->
      true
  | _ -> false

let parse_header_line line =
  let content = String.sub line 0 (String.length line - 2) in
  match String.index_opt content ':' with
  | None -> raise (Http_protocol "invalid HTTP header line")
  | Some colon ->
      let name = String.sub content 0 colon in
      let value =
        String.trim
          (String.sub content (colon + 1) (String.length content - colon - 1))
      in
      if name = "" || not (String.for_all http_token_char name) then
        raise (Http_protocol "invalid HTTP header line");
      if String.exists (fun char -> Char.code char < 0x20 && char <> '\t') value
      then raise (Http_protocol "invalid HTTP header line");
      (String.lowercase_ascii name, value)

let header_values name headers =
  List.filter_map
    (fun (key, value) -> if key = name then Some value else None)
    headers

let single_header name headers =
  match header_values name headers with
  | [ value ] -> Ok value
  | [] -> Error ("omitted " ^ name)
  | _ -> Error ("repeated " ^ name)

(* Comma-separated header lists such as Connection carry tokens, so a value of
   "keep-alive, Upgrade" satisfies a required "upgrade" token while a prefix
   match on the whole value would not. *)
let header_tokens value =
  String.split_on_char ',' value
  |> List.map (fun token -> String.lowercase_ascii (String.trim token))

let read_http_response_until ?interrupt channel deadline =
  let status_line = read_line_until ?interrupt channel deadline in
  let status_code =
    try
      if
        String.length status_line < 14
        || String.sub status_line 0 5 <> "HTTP/"
        || status_line.[8] <> ' '
      then raise Exit;
      let code = String.sub status_line 9 3 in
      if String.exists (fun char -> char < '0' || char > '9') code then
        raise Exit;
      let separator = status_line.[12] in
      if separator <> ' ' && separator <> '\r' then raise Exit;
      if
        separator = '\r'
        && (String.length status_line <> 14 || status_line.[13] <> '\n')
      then raise Exit;
      let value = int_of_string code in
      (* The checks above already require exactly three digits. A 0xx code
         still names no status that any HTTP version defines. *)
      if value < 100 then raise Exit else value
    with _ -> raise (Http_protocol "invalid HTTP status line")
  in
  let rec read_headers remaining acc =
    if remaining <= 0 then
      raise (Http_protocol "HTTP response has too many header lines")
    else
      let line = read_line_until ?interrupt channel deadline in
      if line = "\r\n" then List.rev acc
      else read_headers (remaining - 1) (parse_header_line line :: acc)
  in
  let headers = read_headers max_http_header_lines [] in
  let content_length =
    List.fold_left
      (fun previous value ->
        let length = parse_content_length value in
        match previous with
        | Some earlier when earlier <> length ->
            raise (Http_protocol "conflicting HTTP Content-Length headers")
        | _ -> Some length)
      None
      (header_values "content-length" headers)
  in
  let chunked =
    List.fold_left
      (fun chunked value ->
        match String.lowercase_ascii value with
        | "chunked" -> true
        | "identity" -> chunked
        | _ -> raise (Http_protocol "unsupported HTTP Transfer-Encoding"))
      false
      (header_values "transfer-encoding" headers)
  in
  (* A response carrying both framings is unrecoverable rather than merely
     redundant: the two lengths can disagree, and picking either one is how a
     client gets talked into reading the next response as this one's body. *)
  if chunked && content_length <> None then
    raise
      (Http_protocol
         "HTTP response used both Content-Length and chunked encoding");
  (* A 101 has no body at all. Believing a Content-Length or chunked header on
     one would consume the first WebSocket frames as if they were HTTP. *)
  if status_code = 101 && (chunked || content_length <> None) then
    raise (Http_protocol "HTTP 101 response must not carry a body framing");
  let read_body () =
    match (content_length, chunked) with
    | Some length, _ when length <= max_http_body ->
        Bytes.to_string (read_exact_until ?interrupt channel length deadline)
    | Some _, _ -> raise (Http_protocol "HTTP response exceeds 2097152 bytes")
    | None, true ->
        let output = Buffer.create 256 in
        let rec chunks () =
          let size =
            parse_chunk_size (read_line_until ?interrupt channel deadline)
          in
          if size = 0 then
            let rec trailers remaining =
              if remaining <= 0 then
                raise (Http_protocol "HTTP response has too many trailers")
              else
                let line = read_line_until ?interrupt channel deadline in
                if line <> "\r\n" then trailers (remaining - 1)
            in
            trailers max_http_trailer_lines
          else (
            if Buffer.length output + size > max_http_body then
              raise (Http_protocol "HTTP response exceeds 2097152 bytes");
            Buffer.add_string output
              (Bytes.to_string
                 (read_exact_until ?interrupt channel size deadline));
            if read_line_until ?interrupt channel deadline <> "\r\n" then
              raise (Http_protocol "invalid HTTP chunk terminator");
            chunks ())
        in
        chunks ();
        Buffer.contents output
    | None, false
      when status_code < 200 || status_code = 204 || status_code = 304 ->
        (* These statuses never carry a body. Returning at once also keeps the
           101 upgrade from waiting for a close that never comes. *)
        ""
    | None, false ->
        (* The request asked for Connection: close, so an unframed body runs to
           end of stream. Cap it exactly like the framed cases. *)
        let output = Buffer.create 256 in
        let block = Bytes.create 8192 in
        let rec drain () =
          match read_some_until ?interrupt channel block 0 8192 deadline with
          | count ->
              if Buffer.length output + count > max_http_body then
                raise (Http_protocol "HTTP response exceeds 2097152 bytes");
              Buffer.add_subbytes output block 0 count;
              drain ()
          | exception Channel_closed -> ()
        in
        drain ();
        Buffer.contents output
  in
  (status_code, headers, read_body ())

let http_call endpoint ~client_version ~auth_token ~timeout operation path args
    =
  protect_error ("HTTP " ^ operation) (fun () ->
      if path = "" then raise (Http_protocol "Convex function path is required");
      let deadline = deadline_after timeout in
      let channel = open_channel ~deadline endpoint in
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
          write_string_until channel request deadline;
          let status_code, _headers, response_body =
            read_http_response_until channel deadline
          in
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

(* RFC 6455 binds a handshake response to the key the client just generated with
   SHA-1. OCaml's standard library ships only MD5 and the pinned image installs
   no digest package, so the 160-bit digest is implemented here. It exists to
   prove the peer answered this handshake, never as a security primitive; the
   published RFC vectors pin it in the language-local fixtures. *)
let sha1 message =
  let mask = 0xffffffff in
  let rotate value amount =
    (value lsl amount) lor (value lsr (32 - amount)) land mask
  in
  let state =
    [| 0x67452301; 0xefcdab89; 0x98badcfe; 0x10325476; 0xc3d2e1f0 |]
  in
  let length = String.length message in
  (* One 0x80 byte, then zero padding, then the length in bits as a big-endian
     64-bit count, rounded up to whole 64-byte blocks. *)
  let padded_length = ((length + 8) / 64 * 64) + 64 in
  let block = Bytes.make padded_length '\000' in
  Bytes.blit_string message 0 block 0 length;
  Bytes.set block length '\x80';
  let bits = Int64.of_int (length * 8) in
  for index = 0 to 7 do
    Bytes.set block
      (padded_length - 1 - index)
      (Char.chr
         (Int64.to_int
            (Int64.logand (Int64.shift_right_logical bits (index * 8)) 255L)))
  done;
  let words = Array.make 80 0 in
  for start = 0 to (padded_length / 64) - 1 do
    for index = 0 to 15 do
      let offset = (start * 64) + (index * 4) in
      words.(index) <-
        (Char.code (Bytes.get block offset) lsl 24)
        lor (Char.code (Bytes.get block (offset + 1)) lsl 16)
        lor (Char.code (Bytes.get block (offset + 2)) lsl 8)
        lor Char.code (Bytes.get block (offset + 3))
    done;
    for index = 16 to 79 do
      words.(index) <-
        rotate
          (words.(index - 3)
          lxor words.(index - 8)
          lxor words.(index - 14)
          lxor words.(index - 16))
          1
    done;
    let a = ref state.(0) in
    let b = ref state.(1) in
    let c = ref state.(2) in
    let d = ref state.(3) in
    let e = ref state.(4) in
    for index = 0 to 79 do
      let mixed, constant =
        if index < 20 then (!b land !c lor (!b lxor mask land !d), 0x5a827999)
        else if index < 40 then (!b lxor !c lxor !d, 0x6ed9eba1)
        else if index < 60 then
          (!b land !c lor (!b land !d) lor (!c land !d), 0x8f1bbcdc)
        else (!b lxor !c lxor !d, 0xca62c1d6)
      in
      let next =
        (rotate !a 5 + mixed + !e + constant + words.(index)) land mask
      in
      e := !d;
      d := !c;
      c := rotate !b 30;
      b := !a;
      a := next
    done;
    state.(0) <- (state.(0) + !a) land mask;
    state.(1) <- (state.(1) + !b) land mask;
    state.(2) <- (state.(2) + !c) land mask;
    state.(3) <- (state.(3) + !d) land mask;
    state.(4) <- (state.(4) + !e) land mask
  done;
  let digest = Bytes.create 20 in
  for index = 0 to 4 do
    let value = state.(index) in
    Bytes.set digest (index * 4) (Char.chr ((value lsr 24) land 255));
    Bytes.set digest ((index * 4) + 1) (Char.chr ((value lsr 16) land 255));
    Bytes.set digest ((index * 4) + 2) (Char.chr ((value lsr 8) land 255));
    Bytes.set digest ((index * 4) + 3) (Char.chr (value land 255))
  done;
  digest

let websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
let websocket_accept_key key = base64_encode (sha1 (key ^ websocket_guid))

let random_bytes length =
  let fd = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      read_exact
        { fd; ssl = None; closed = false; nonblocking = false }
        length 5.0)

type ws = {
  channel : channel;
  interrupt : Unix.file_descr;
  mutable fragment_opcode : int option;
  fragments : Buffer.t;
  (* Bytes already pulled out of [channel] but not yet handed to a frame
     reader. A single [Ssl.read] can return more than one WebSocket frame's
     worth of plaintext: TLS records and WebSocket frames do not line up, and
     OpenSSL keeps whatever a caller's buffer was too small to hold in a
     buffer of its own, inside the process, invisible to a later [select] on
     the raw file descriptor. Reading through this buffer instead of straight
     from [channel] is what keeps that leftover plaintext from being mistaken
     for "nothing to read" the next time [ws_has_buffered] is asked. *)
  mutable read_buffer : Bytes.t;
  mutable read_start : int;
  mutable read_length : int;
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
  write_all ~interrupt:ws.interrupt ws.channel header 0 (Bytes.length header);
  write_all ~interrupt:ws.interrupt ws.channel body 0 length

let max_websocket_message = 2 * 1024 * 1024
let max_websocket_control_payload = 125
let live_read_timeout = 30.0
let ws_read_buffer_capacity = 8192

(* Refill [ws.read_buffer] with one underlying read. This is the only place
   that touches [ws.channel] directly; a short read here is normal (the
   kernel or OpenSSL had less immediately available than the buffer's
   capacity) and is not distinguished from a full one. *)
let ws_fill ws deadline =
  ws.read_start <- 0;
  ws.read_length <-
    read_some_until ~interrupt:ws.interrupt ws.channel ws.read_buffer 0
      (Bytes.length ws.read_buffer)
      deadline

(* True once bytes are sitting in [ws.read_buffer] unconsumed. A previous
   [ws_fill] can have pulled in more than the caller asked for, and that
   remainder cannot be observed at the socket: [select] on the raw file
   descriptor reports nothing new until the peer sends more, even while a
   complete frame is already sitting here decrypted and ready. *)
let ws_has_buffered ws = ws.read_start < ws.read_length

let ws_read_some ws bytes offset length deadline =
  if not (ws_has_buffered ws) then ws_fill ws deadline;
  let available = ws.read_length - ws.read_start in
  let count = min available length in
  Bytes.blit ws.read_buffer ws.read_start bytes offset count;
  ws.read_start <- ws.read_start + count;
  count

let ws_read_exact ws length deadline =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then bytes
    else loop (offset + ws_read_some ws bytes offset (length - offset) deadline)
  in
  loop 0

(* One deadline covers the whole frame. A peer that dribbles a byte at a time
   cannot keep resetting the clock, and a timeout mid-frame is fatal to the
   connection rather than something the caller may retry at a false boundary.

   Every structural rule RFC 6455 gives a client is checked here, before any
   payload is consumed, because each one is a way for a peer to describe a
   frame differently from the frame it actually sent. *)
let ws_read_frame ws timeout =
  let deadline = deadline_after timeout in
  let header = ws_read_exact ws 2 deadline in
  let first, second =
    (Char.code (Bytes.get header 0), Char.code (Bytes.get header 1))
  in
  let fin = first land 0x80 <> 0 in
  (* This client negotiates no extension, so a reserved bit has no meaning it
     could act on and the frame cannot be interpreted. *)
  if first land 0x70 <> 0 then
    raise (Websocket_protocol "WebSocket frame set a reserved bit");
  let opcode = first land 0x0f in
  (match opcode with
  | 0 | 1 | 2 | 8 | 9 | 10 -> ()
  | _ -> raise (Websocket_protocol "WebSocket frame used a reserved opcode"));
  let control = opcode land 0x08 <> 0 in
  (* A server must never mask. Accepting a masked frame would also let a peer
     hide the real payload behind a key we were not required to read. *)
  if second land 0x80 <> 0 then
    raise (Websocket_protocol "WebSocket server frame was masked");
  let short_length = second land 0x7f in
  if control && not fin then
    raise (Websocket_protocol "WebSocket control frame was fragmented");
  if control && short_length > max_websocket_control_payload then
    raise (Websocket_protocol "WebSocket control frame exceeds 125 bytes");
  let length =
    if short_length < 126 then short_length
    else if short_length = 126 then (
      let bytes = ws_read_exact ws 2 deadline in
      let value =
        (Char.code (Bytes.get bytes 0) lsl 8) lor Char.code (Bytes.get bytes 1)
      in
      (* A non-minimal length is the same byte count described two ways. One
         spelling is the protocol's; the other is a peer probing what this
         parser will accept. *)
      if value < 126 then
        raise
          (Websocket_protocol "WebSocket frame length was not minimally encoded");
      value)
    else
      let bytes = ws_read_exact ws 8 deadline in
      if Char.code (Bytes.get bytes 0) land 0x80 <> 0 then
        raise (Websocket_protocol "WebSocket frame length has its top bit set");
      let value = ref 0L in
      for index = 0 to 7 do
        value :=
          Int64.logor
            (Int64.shift_left !value 8)
            (Int64.of_int (Char.code (Bytes.get bytes index)))
      done;
      if Int64.compare !value 65536L < 0 then
        raise
          (Websocket_protocol "WebSocket frame length was not minimally encoded");
      if Int64.compare !value (Int64.of_int max_websocket_message) > 0 then
        raise (Websocket_protocol "WebSocket message exceeds 2097152 bytes");
      Int64.to_int !value
  in
  if length > max_websocket_message then
    raise (Websocket_protocol "WebSocket message exceeds 2097152 bytes");
  let payload = ws_read_exact ws length deadline in
  (fin, opcode, Bytes.to_string payload)

(* A close frame either carries nothing or carries a code plus a UTF-8 reason.
   A single byte cannot be a code, and the codes below are the ones RFC 6455
   and the IANA registry allow a peer to send on the wire. *)
let websocket_close_reason payload =
  let length = String.length payload in
  if length = 0 then "server close"
  else if length = 1 then
    raise
      (Websocket_protocol "WebSocket close frame carried a one byte payload")
  else
    let code = (Char.code payload.[0] lsl 8) lor Char.code payload.[1] in
    let permitted =
      (code >= 1000 && code <= 1003)
      || (code >= 1007 && code <= 1011)
      || (code >= 3000 && code <= 4999)
    in
    if not permitted then
      raise (Websocket_protocol "WebSocket close frame used an invalid code");
    if not (valid_utf8 (String.sub payload 2 (length - 2))) then
      raise (Websocket_protocol "WebSocket close reason was not valid UTF-8");
    "server close " ^ string_of_int code

let websocket_text value =
  if valid_utf8 value then value
  else raise (Websocket_protocol "WebSocket text message was not valid UTF-8")

let ws_read_message ws =
  let rec loop () =
    let fin, opcode, payload = ws_read_frame ws live_read_timeout in
    match opcode with
    | 8 -> raise (Websocket_closed (websocket_close_reason payload))
    | 9 ->
        ws_write_frame ws 10 payload;
        loop ()
    | 10 -> loop ()
    | 0 -> (
        match ws.fragment_opcode with
        | None -> raise (Websocket_protocol "unexpected WebSocket continuation")
        | Some _ ->
            (* The per-frame limit says nothing about a message split into many
               frames, so the accumulated total is what has to be bounded. *)
            if
              Buffer.length ws.fragments + String.length payload
              > max_websocket_message
            then
              raise
                (Websocket_protocol "WebSocket message exceeds 2097152 bytes");
            Buffer.add_string ws.fragments payload;
            if fin then (
              let value = Buffer.contents ws.fragments in
              Buffer.clear ws.fragments;
              ws.fragment_opcode <- None;
              websocket_text value)
            else loop ())
    | 1 ->
        if ws.fragment_opcode <> None then
          raise
            (Websocket_protocol
               "WebSocket data frame interrupted a fragmented message");
        if fin then websocket_text payload
        else (
          Buffer.clear ws.fragments;
          Buffer.add_string ws.fragments payload;
          ws.fragment_opcode <- Some opcode;
          loop ())
    | _ -> raise (Websocket_protocol "unsupported WebSocket opcode")
  in
  loop ()

let live_handshake_timeout = 30.0

(* HTTP 101 alone only says "something switched protocols". These four checks
   are what make the response an answer to *this* upgrade: the peer must name
   the websocket protocol, must actually mean the Upgrade token in its
   Connection list, must echo the accept value derived from the key generated
   moments ago, and must not select an extension or subprotocol that was never
   offered and that this frame reader could not honour. Without them a cached
   or misrouted 101 would be treated as a live Convex sync socket. *)
let validate_websocket_handshake ~key ~status ~headers =
  if status <> 101 then
    raise
      (Websocket_protocol
         ("WebSocket handshake returned HTTP " ^ string_of_int status));
  let required name =
    match single_header name headers with
    | Ok value -> value
    | Error message ->
        raise (Websocket_protocol ("WebSocket handshake " ^ message))
  in
  if String.lowercase_ascii (required "upgrade") <> "websocket" then
    raise
      (Websocket_protocol "WebSocket handshake did not upgrade to websocket");
  if not (List.mem "upgrade" (header_tokens (required "connection"))) then
    raise
      (Websocket_protocol
         "WebSocket handshake omitted the Upgrade connection token");
  if required "sec-websocket-accept" <> websocket_accept_key key then
    raise
      (Websocket_protocol
         "WebSocket handshake returned an incorrect Sec-WebSocket-Accept");
  if
    List.exists
      (fun (name, _) ->
        name = "sec-websocket-extensions" || name = "sec-websocket-protocol")
      headers
  then
    raise
      (Websocket_protocol
         "WebSocket handshake selected an unrequested extension or subprotocol")

(* The socket owner runs the handshake inline, so an unbounded connect would
   also block close, unsubscribe, and debugDisconnect. One deadline bounds DNS,
   connect, TLS, and the upgrade exchange, and the wake pipe abandons the
   attempt as soon as a controller command arrives. *)
let websocket_connect endpoint ~client_version ~auth_token ~interrupt =
  let deadline = deadline_after live_handshake_timeout in
  let channel = open_channel ~interrupt ~deadline endpoint in
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
    write_string_until ~interrupt channel request deadline;
    let status, headers, _ =
      read_http_response_until ~interrupt channel deadline
    in
    validate_websocket_handshake ~key ~status ~headers;
    {
      channel;
      interrupt;
      fragment_opcode = None;
      fragments = Buffer.create 256;
      read_buffer = Bytes.create ws_read_buffer_capacity;
      read_start = 0;
      read_length = 0;
    }
  with error ->
    close_channel channel;
    raise error

type update = { value : J.t option; error : error option; logs : string list }

(* [charge] is the accounted memory cost of holding this update, and [sequence]
   is a process-wide arrival order so an overflowing budget can evict the
   globally oldest update rather than a locally oldest one. *)
type queued_update = { queued : update; charge : int; sequence : int }

type subscription_state = {
  qid : int;
  path : string;
  args : J.t;
  mutable queue : queued_update list;
  mutable closed : bool;
}

(* ------------------------------------------------------------------------
   Live delivery budget

   The shared conformance gate runs this client's container with
   --memory 128m, and a single sync message may be almost the 2 MiB frame
   limit, so an event count is not a memory bound. The budget below is
   process-wide rather than per subscription: twenty slow subscriptions each
   holding "only" a few megabytes is exactly how a per-subscription bound
   passes its own test and still runs the container out of memory.

   The 128 MiB gate is divided before anything is allowed to be retained:

     - the OCaml runtime, OpenSSL, the worker and relay thread stacks, and
       the major heap the collector has not yet returned;
     - the transient peak of one inbound frame: its raw bytes, the string it
       is decoded into, and the JSON tree parsed from it;
     - the test adapter's whole output path, which is three times its own
       queue budget: the queued lines, the values its relays have taken from
       these queues, and the encoded copies of those values;
     - explicit headroom so the gate is a bound, not a target.

   What is left is halved, because OCaml's major heap can hold roughly twice
   the live set before a collection returns it. Every retained update is
   charged for its value, its logs, its structured error data, and an equal
   allowance for the encoded output that value will become. *)
let live_memory_limit_bytes = 128 * 1024 * 1024
let live_runtime_reserve_bytes = 32 * 1024 * 1024
let live_transient_reserve_bytes = 24 * 1024 * 1024
let live_writer_reserve_bytes = 24 * 1024 * 1024
let live_headroom_bytes = 16 * 1024 * 1024
let live_heap_factor = 2

let max_queue_bytes =
  (live_memory_limit_bytes - live_runtime_reserve_bytes
 - live_transient_reserve_bytes - live_writer_reserve_bytes
 - live_headroom_bytes)
  / live_heap_factor

(* A process-wide count bound as well, so a flood of tiny updates cannot cost
   an unbounded number of list cells while staying under the byte budget. *)
let max_queue_items = 256

(* One slow subscription still may not fill the whole process budget on its
   own. This is subordinate to the two bounds above, not a replacement. *)
let max_subscription_items = 16
let queued_update_overhead_bytes = 512
let encoded_output_factor = 2

(* An estimate of what a decoded JSON value costs in the OCaml heap, walked
   with an explicit stack so a deeply nested value cannot overflow the
   measuring thread. The per-node constants are deliberately generous: a list
   of small integers costs far more as boxed cells than it did as text, and
   charging by encoded length would under-count exactly that shape. *)
let json_footprint (json : J.t) =
  let rec walk acc (stack : J.t list) =
    match stack with
    | [] -> acc
    | value :: rest -> (
        match value with
        | `Null | `Bool _ -> walk (acc + 16) rest
        | `Int _ -> walk (acc + 24) rest
        | `Float _ -> walk (acc + 32) rest
        | `String text | `Intlit text ->
            walk (acc + 32 + String.length text) rest
        | `List items | `Tuple items ->
            walk
              (acc + 24 + (24 * List.length items))
              (List.rev_append items rest)
        | `Variant (name, payload) ->
            walk
              (acc + 32 + String.length name)
              (match payload with None -> rest | Some value -> value :: rest)
        | `Assoc fields ->
            walk
              (List.fold_left
                 (fun acc (name, _) -> acc + 56 + String.length name)
                 (acc + 24) fields)
              (List.rev_append (List.map snd fields) rest))
  in
  walk 0 [ json ]

let logs_footprint logs =
  List.fold_left (fun acc line -> acc + 32 + String.length line) 24 logs

let error_footprint = function
  | Function_error { operation; message; data; logs } ->
      String.length operation + String.length message
      + (match data with None -> 0 | Some value -> json_footprint value)
      + logs_footprint logs
  | Protocol_error message -> String.length message
  | Http_error { operation; message; _ } ->
      String.length operation + String.length message
  | Transport_error { operation; message } ->
      String.length operation + String.length message
  | Closed -> 0

let update_charge update =
  queued_update_overhead_bytes
  + encoded_output_factor
    * ((match update.value with
       | None -> 0
       | Some value -> json_footprint value)
      + (match update.error with
        | None -> 0
        | Some error -> error_footprint error)
      + logs_footprint update.logs)

(* Every subscription queue in the process is guarded by this one mutex, which
   is also what makes the shared counters and the eviction scan consistent
   without any lock ordering to get wrong. *)
let live_queue_mutex = Mutex.create ()
let live_queue_bytes = ref 0
let live_queue_items = ref 0
let live_queue_sequence = ref 0
let live_queue_states : subscription_state list ref = ref []

let with_live_queue f =
  Mutex.lock live_queue_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock live_queue_mutex) f

(* Closed subscriptions stay registered until their queue is drained, because a
   consumer is still entitled to the updates that arrived before the close. *)
let prune_states_locked () =
  live_queue_states :=
    List.filter
      (fun state -> not (state.closed && state.queue = []))
      !live_queue_states

let register_state state =
  with_live_queue (fun () -> live_queue_states := state :: !live_queue_states)

let drop_oldest_locked state =
  match state.queue with
  | [] -> ()
  | oldest :: rest ->
      state.queue <- rest;
      live_queue_bytes := !live_queue_bytes - oldest.charge;
      live_queue_items := !live_queue_items - 1

(* When the process budget is exceeded, the globally oldest queued update is
   the one whose loss costs a consumer the least: it is the update furthest
   behind current state anywhere in the client. *)
let evict_locked () =
  let rec evict () =
    if
      !live_queue_bytes > max_queue_bytes || !live_queue_items > max_queue_items
    then
      let oldest =
        List.fold_left
          (fun oldest state ->
            match (state.queue, oldest) with
            | [], _ -> oldest
            | head :: _, Some (_, sequence) when head.sequence >= sequence ->
                oldest
            | head :: _, _ -> Some (state, head.sequence))
          None !live_queue_states
      in
      match oldest with
      | None -> ()
      | Some (state, _) ->
          drop_oldest_locked state;
          evict ()
  in
  evict ()

let enqueue state update =
  let charge = update_charge update in
  with_live_queue (fun () ->
      if not state.closed then (
        incr live_queue_sequence;
        let entry =
          { queued = update; charge; sequence = !live_queue_sequence }
        in
        state.queue <- state.queue @ [ entry ];
        live_queue_bytes := !live_queue_bytes + charge;
        incr live_queue_items;
        while List.length state.queue > max_subscription_items do
          drop_oldest_locked state
        done;
        evict_locked ()))

let close_state state =
  with_live_queue (fun () ->
      state.closed <- true;
      prune_states_locked ())

let dequeue state timeout =
  let deadline = monotonic_now () +. timeout in
  let rec loop () =
    let taken =
      with_live_queue (fun () ->
          match state.queue with
          | entry :: rest ->
              state.queue <- rest;
              live_queue_bytes := !live_queue_bytes - entry.charge;
              live_queue_items := !live_queue_items - 1;
              if state.closed && rest = [] then prune_states_locked ();
              `Update entry.queued
          | [] when state.closed -> `Closed
          | [] -> `Empty)
    in
    match taken with
    | `Update update -> Some update
    | `Closed -> None
    | `Empty ->
        if timeout >= 0.0 && monotonic_now () >= deadline then None
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
  (* Filled in once [Thread.create] returns. The owner never reads it, so the
     manager the worker captured and the manager the client holds must stay the
     same record: copying it would strand every later [auth_token] change. *)
  mutable owner : Thread.t option;
}

(* [auth_token] crosses from the caller's thread to the socket owner. *)
let manager_auth (manager : live_manager) =
  Mutex.lock manager.command_mutex;
  let token = manager.auth_token in
  Mutex.unlock manager.command_mutex;
  token

type client = {
  endpoint : endpoint;
  client_version : string;
  http_timeout : float;
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

(* [J.equal] rather than structural equality: the server may re-encode an
   unchanged value differently, and only a JSON-aware comparison notices. *)
let same_value left right =
  match (left, right) with
  | Some left, Some right -> equal_json left right
  | None, None -> true
  | Some _, None | None, Some _ -> false

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

(* Reconnect delay bounds. The floor is also what a healthy connection resets
   to, so an intervening good connection never inherits an old maximum. *)
let live_initial_backoff = 0.1
let live_maximum_backoff = 15.0

let live_owner (manager : live_manager) =
  let active : (int, subscription_state) Hashtbl.t = Hashtbl.create 8 in
  let last_delivered : (int, update) Hashtbl.t = Hashtbl.create 8 in
  let awaiting : (int, bool) Hashtbl.t = Hashtbl.create 8 in
  let connection = ref None in
  let query_set_version = ref 0 in
  let remote_version = ref (zero_version ()) in
  let connection_count = ref 0 in
  let last_close_reason = ref "InitialConnect" in
  let max_timestamp : string option ref = ref None in
  let reconnect_at = ref None in
  let backoff = ref live_initial_backoff in
  let retired_for_disconnect = ref false in
  let set_reconnect delay = reconnect_at := Some (monotonic_now () +. delay) in
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
      backoff := min live_maximum_backoff (!backoff *. 2.0))
    else reconnect_at := None
  in
  let deliver qid update =
    match Hashtbl.find_opt active qid with
    | Some state -> enqueue state update
    | None -> ()
  in
  let protocol_failure error =
    let logs = error_logs error in
    let update = { value = None; error = Some error; logs } in
    Hashtbl.iter
      (fun qid (_ : subscription_state) ->
        (* Record the failure as the delivered state. Without this the next
           connection rehydrates the same value the subscriber last saw before
           the error, the unchanged-value suppression drops it, and an
           otherwise healthy subscription is stranded on the error. *)
        Hashtbl.replace last_delivered qid update;
        deliver qid update)
      active
  in
  let queued_disconnect () =
    Mutex.lock manager.command_mutex;
    let found =
      Queue.fold
        (fun found command ->
          found
          ||
          match command with
          | Disconnect _ -> true
          | Add _ | Remove _ | Stop -> false)
        false manager.commands
    in
    Mutex.unlock manager.command_mutex;
    found
  in
  let connect () =
    try
      let ws =
        websocket_connect manager.endpoint
          ~client_version:manager.client_version
          ~auth_token:(manager_auth manager) ~interrupt:manager.wake_read
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
      reconnect_at := None;
      (* The handshake was validated and this connection has already carried the
         Connect message and the replayed Add operations, so the delay that got
         us here has been paid off. A later failure starts from the floor again
         rather than inheriting the previous connection's maximum. *)
      backoff := live_initial_backoff
    with
    | Read_interrupted ->
        (* A controller command arrived mid-handshake. Retire this attempt so
           the command loop runs, and record the reason the same way the read
           path does so a queued debugDisconnect still sees a retired socket. *)
        retired_for_disconnect := queued_disconnect ();
        if !connection = None then incr connection_count;
        close_connection
          (if !retired_for_disconnect then "DebugDisconnect"
           else "ControllerCommand")
          true
    | error ->
        (* Count this connection exactly once. [close_connection] already
           counts an attempt that got as far as a live socket. *)
        if !connection = None then incr connection_count;
        close_connection (Printexc.to_string error) true
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
    let modifications =
      match assoc "modifications" json with
      | `List values -> values
      | _ -> raise (Failure "Transition modifications must be an array")
    in
    let timestamp =
      match string_member "ts" end_version with
      | Some value -> value
      | None -> raise (Failure "Transition endVersion omitted ts")
    in
    (* Whether this transition's timestamp becomes the new watermark. Computed
       now, alongside every other validation, but not written to
       [max_timestamp] until the transition is known to be valid in full. *)
    let advances_max_timestamp =
      match !max_timestamp with
      | None -> true
      | Some previous -> (
          match compare_timestamps timestamp previous with
          | Ok comparison -> comparison > 0
          | Error _ as error ->
              raise
                (Failure
                   (error_message
                      (match error with
                      | Error value -> value
                      | Ok _ -> assert false))))
    in
    (* Query IDs are handed out by this client, counting up from zero. An ID
       this client has issued but already removed can still appear in a
       transition the server had in flight, so it is dropped rather than
       retained. An ID that was never issued is not late bookkeeping: it names
       a query this client cannot serve, and remembering it in [last_delivered]
       would grow with every such message and answer for a real query later. *)
    let issued qid =
      Mutex.lock manager.command_mutex;
      let next = manager.next_qid in
      Mutex.unlock manager.command_mutex;
      qid >= 0 && qid < next
    in
    (* Every modification is parsed into an action here, without touching
       [last_delivered], [awaiting], or [changed]. A later modification in the
       same message failing to parse must not leave an earlier one already
       committed: half of a rejected transition is not a smaller valid one. *)
    let action_of modification =
      let qid = int_member "queryId" modification in
      match string_member "type" modification with
      | Some ("QueryUpdated" | "QueryFailed") when not (Hashtbl.mem active qid)
        ->
          if not (issued qid) then
            raise
              (Failure ("Transition names unknown query " ^ string_of_int qid));
          `Forget qid
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
          `Applied (qid, update)
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
          let logs =
            match list_string_member "logLines" modification with
            | Ok values -> values
            | Error _ -> []
          in
          let update =
            {
              value = None;
              error =
                Some
                  (Function_error { operation = "query"; message; data; logs });
              logs;
            }
          in
          `Applied (qid, update)
      | Some "QueryRemoved" -> `Removed qid
      | Some other ->
          raise (Failure ("unknown Transition modification " ^ other))
      | None -> raise (Failure "Transition modification omitted type")
    in
    let actions = List.map action_of modifications in
    (* Every modification validated. Only now does the transition touch
       [last_delivered], [remote_version], or [max_timestamp], and all three
       move together so a later message can never observe one without the
       others. *)
    let changed = Hashtbl.create 4 in
    List.iter
      (fun action ->
        match action with
        | `Forget qid ->
            Hashtbl.remove last_delivered qid;
            Hashtbl.remove awaiting qid
        | `Applied (qid, update) when update.error = None ->
            let previous = Hashtbl.find_opt last_delivered qid in
            Hashtbl.replace last_delivered qid update;
            if Hashtbl.mem awaiting qid then (
              Hashtbl.remove awaiting qid;
              (* Suppress a rehydration that repeats what the subscriber
                 already has: a reconnect must not replay it as a change. *)
              match previous with
              | Some previous
                when previous.error = None
                     && same_value previous.value update.value ->
                  ()
              | _ -> Hashtbl.replace changed qid update)
            else Hashtbl.replace changed qid update
        | `Applied (qid, update) ->
            Hashtbl.remove awaiting qid;
            Hashtbl.replace last_delivered qid update;
            Hashtbl.replace changed qid update
        | `Removed qid ->
            Hashtbl.remove last_delivered qid;
            Hashtbl.remove awaiting qid)
      actions;
    remote_version := end_version;
    if advances_max_timestamp then max_timestamp := Some timestamp;
    Hashtbl.iter (fun qid update -> deliver qid update) changed;
    backoff := live_initial_backoff
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
    (* [ws_has_buffered] is what notices a frame [ws_fill] already pulled out
       of TLS but this loop has not yet consumed. Without it, the [select]
       below blocks for the full timeout while that frame sits decrypted and
       unread: TLS records do not line up with WebSocket frames, so a single
       underlying read can leave a second, complete one buffered with
       nothing left at the raw file descriptor for [select] to see. *)
    let pending =
      match !connection with Some ws -> ws_has_buffered ws | None -> false
    in
    let timeout =
      if pending then 0.0
      else
        match !reconnect_at with
        | None -> 30.0
        | Some at -> max 0.0 (at -. monotonic_now ())
    in
    let descriptors =
      manager.wake_read
      :: (match !connection with Some ws -> [ ws.channel.fd ] | None -> [])
    in
    (* An uncaught EINTR here would kill the only thread that owns the socket,
       and every later close, unsubscribe, and relay join would wait forever. *)
    let rec select () =
      try Unix.select descriptors [] [] timeout
      with Unix.Unix_error (Unix.EINTR, _, _) -> select ()
    in
    let ready, _, _ = select () in
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
              close_state state
          | Disconnect reply ->
              if !connection = None && not !retired_for_disconnect then
                reply :=
                  Some
                    (Error
                       (Transport_error
                          {
                            operation = "live disconnect";
                            message = "WebSocket is not connected";
                          }))
              else (
                if !connection <> None then
                  close_connection "DebugDisconnect" true
                else last_close_reason := "DebugDisconnect";
                retired_for_disconnect := false;
                reply := Some (Ok ()))
          | Stop ->
              close_connection "ClientClosed" false;
              Hashtbl.iter
                (fun (_ : int) (state : subscription_state) ->
                  close_state state)
                active;
              manager.closed <- true)
        (drain_commands ());
      if manager.closed then () else loop ())
    else (
      (match !reconnect_at with
      | Some at when at <= monotonic_now () && !connection = None -> connect ()
      | _ -> ());
      match !connection with
      | Some ws when pending || List.mem ws.channel.fd ready ->
          (try handle_message (J.from_string (ws_read_message ws)) with
          | Read_interrupted ->
              retired_for_disconnect := queued_disconnect ();
              close_connection
                (if !retired_for_disconnect then "DebugDisconnect"
                 else "ControllerCommand")
                true
          | error ->
              let message = Printexc.to_string error in
              protocol_failure (Protocol_error message);
              close_connection message true);
          if not manager.closed then loop ()
      | _ -> if not manager.closed then loop ())
  in
  loop ()

let create ?(http_timeout = 30.0) raw_url =
  let invalid_timeout =
    match classify_float http_timeout with
    | FP_nan | FP_infinite -> true
    | FP_normal | FP_subnormal | FP_zero -> http_timeout <= 0.0
  in
  if invalid_timeout then
    Error (Protocol_error "HTTP timeout must be finite and positive")
  else
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
            owner = None;
          }
        in
        manager.owner <- Some (Thread.create (fun () -> live_owner manager) ());
        Ok
          {
            endpoint;
            client_version = "ocaml-0.1.0";
            http_timeout;
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
  (* The token is interpolated into an Authorization header on both transports,
     so a bare CR or LF would let a caller append headers of their own. *)
  let control char = Char.code char < 0x20 || Char.code char = 0x7f in
  if String.exists control token then
    Error (Protocol_error "auth token must not contain control characters")
  else
    let value = if token = "" then None else Some token in
    Mutex.lock client.mutex;
    if client.closed then (
      Mutex.unlock client.mutex;
      Error Closed)
    else (
      client.auth_token <- value;
      Mutex.lock client.live.command_mutex;
      client.live.auth_token <- value;
      Mutex.unlock client.live.command_mutex;
      Mutex.unlock client.mutex;
      Ok ())

let call client operation path args =
  with_client client operation (fun token ->
      http_call client.endpoint ~client_version:client.client_version
        ~auth_token:token ~timeout:client.http_timeout operation path args)

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
        let state = { qid; path; args; queue = []; closed = false } in
        (* Registering before the Add reaches the owner keeps this queue inside
           the process-wide budget from its very first update. *)
        register_state state;
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
      let deadline = monotonic_now () +. 10.0 in
      let rec wait () =
        match !result with
        | Some value -> value
        | None when monotonic_now () < deadline ->
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
    (match client.live.owner with
    | Some owner -> Thread.join owner
    | None -> ());
    close_channel
      {
        fd = client.live.wake_read;
        ssl = None;
        closed = false;
        nonblocking = false;
      };
    close_channel
      {
        fd = client.live.wake_write;
        ssl = None;
        closed = false;
        nonblocking = false;
      })
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
