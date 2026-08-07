let fail message = raise (Failure message)

module J = Yojson.Safe

let expect_error expected = function
  | Ok _ -> fail ("expected error: " ^ expected)
  | Error message when message = expected -> ()
  | Error message -> fail ("expected " ^ expected ^ ", got " ^ message)

let read_http_request channel =
  let content_length = ref 0 in
  let rec headers () =
    let line = input_line channel in
    if line = "\r" then ()
    else
      let lower = String.lowercase_ascii line in
      let prefix = "content-length:" in
      if
        String.length lower >= String.length prefix
        && String.sub lower 0 (String.length prefix) = prefix
      then
        content_length :=
          int_of_string
            (String.trim
               (String.sub line (String.length prefix)
                  (String.length line - String.length prefix)));
      headers ()
  in
  headers ();
  really_input_string channel !content_length

let with_http_response status body check =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 1;
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let server =
    Thread.create
      (fun () ->
        let socket, _ = Unix.accept listener in
        let input = Unix.in_channel_of_descr socket in
        let output = Unix.out_channel_of_descr socket in
        Fun.protect
          ~finally:(fun () ->
            close_in_noerr input;
            close_out_noerr output;
            Unix.close listener)
          (fun () ->
            ignore (read_http_request input);
            Printf.fprintf output
              "HTTP/1.1 %d fixture\r\n\
               Content-Type: application/json\r\n\
               Content-Length: %d\r\n\
               Connection: close\r\n\
               \r\n\
               %s"
              status (String.length body) body;
            flush output))
      ()
  in
  let client =
    match Convex.create (Printf.sprintf "http://127.0.0.1:%d" port) with
    | Ok value -> value
    | Error error -> fail (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () ->
      Convex.close client;
      Thread.join server)
    (fun () -> check (Convex.query client "tests:fixture" (`Assoc [])))

let expect_protocol_error expected = function
  | Error (Convex.Protocol_error message) when message = expected -> ()
  | Error error ->
      fail
        ("expected ProtocolError, got " ^ Convex.error_name error ^ ": "
       ^ Convex.error_message error)
  | Ok _ -> fail "expected ProtocolError, got success"

type scripted_http_action =
  | Plain_chunks of string list * float
  | Stall_tls of float

let with_scripted_http ~scheme ~timeout actions check =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 4;
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let server =
    Thread.create
      (fun () ->
        Fun.protect
          ~finally:(fun () -> Unix.close listener)
          (fun () ->
            List.iter
              (fun action ->
                let socket, _ = Unix.accept listener in
                let input = Unix.in_channel_of_descr socket in
                let output = Unix.out_channel_of_descr socket in
                Fun.protect
                  ~finally:(fun () ->
                    close_in_noerr input;
                    close_out_noerr output)
                  (fun () ->
                    match action with
                    | Stall_tls seconds -> Thread.delay seconds
                    | Plain_chunks (chunks, delay) -> (
                        ignore (read_http_request input);
                        try
                          List.iter
                            (fun chunk ->
                              output_string output chunk;
                              flush output;
                              if delay > 0.0 then Thread.delay delay)
                            chunks
                        with Sys_error _ | Unix.Unix_error _ -> ())))
              actions))
      ()
  in
  let client =
    match
      Convex.create ~http_timeout:timeout
        (Printf.sprintf "%s://127.0.0.1:%d" scheme port)
    with
    | Ok value -> value
    | Error error -> fail (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () ->
      Convex.close client;
      Thread.join server)
    (fun () -> check client)

let expect_transport_timeout = function
  | Error
      (Convex.Transport_error
         {
           operation = "HTTP query";
           message = "timed out while waiting for the response";
         }) ->
      ()
  | Error error ->
      fail
        ("expected HTTP timeout TransportError, got " ^ Convex.error_name error
       ^ ": " ^ Convex.error_message error)
  | Ok _ -> fail "slow HTTP fixture unexpectedly returned success"

let test_http_absolute_deadlines () =
  let timeout = 0.2 in
  let response_headers =
    "HTTP/1.1 200 OK\r\n\
     Content-Type: application/json\r\n\
     Content-Length: 4\r\n\
     \r\n"
  in
  let cases =
    [
      ( "status",
        [ "H"; "T"; "T"; "P/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnull" ] );
      ( "header",
        [ "HTTP/1.1 200 OK\r\n"; "C"; "o"; "ntent-Length: 4\r\n\r\nnull" ] );
      ("body", [ response_headers; "n"; "u"; "ll" ]);
    ]
  in
  List.iter
    (fun (phase, chunks) ->
      with_scripted_http ~scheme:"http" ~timeout
        [ Plain_chunks (chunks, 0.075) ]
        (fun client ->
          match Convex.query client ("tests:slow-" ^ phase) (`Assoc []) with
          | result -> expect_transport_timeout result))
    cases;
  let recovery_body =
    {|{"status":"success","value":{"recovered":"deadline"}}|}
  in
  let recovery_response =
    Printf.sprintf "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s"
      (String.length recovery_body)
      recovery_body
  in
  with_scripted_http ~scheme:"http" ~timeout
    [
      Plain_chunks ([ response_headers; "n"; "u"; "ll" ], 0.075);
      Plain_chunks ([ recovery_response ], 0.0);
    ]
    (fun client ->
      Convex.query client "tests:slow-then-recover" (`Assoc [])
      |> expect_transport_timeout;
      match Convex.query client "tests:after-deadline" (`Assoc []) with
      | Ok { value = `Assoc [ ("recovered", `String "deadline") ]; logs = [] }
        ->
          ()
      | Ok result ->
          fail ("deadline recovery returned " ^ J.to_string result.value)
      | Error error -> fail (Convex.error_message error));
  with_scripted_http ~scheme:"https" ~timeout [ Stall_tls 0.35 ] (fun client ->
      expect_transport_timeout
        (Convex.query client "tests:stalled-tls" (`Assoc [])))

let test_malformed_status_recovery () =
  let body = {|{"status":"success","value":{"recovered":true}}|} in
  let valid =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      (String.length body) body
  in
  let malformed suffix =
    "HTTP/1.1 " ^ suffix
    ^ " Bad\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  in
  with_scripted_http ~scheme:"http" ~timeout:1.0
    [
      Plain_chunks ([ malformed "2000" ], 0.0);
      Plain_chunks ([ malformed "200X" ], 0.0);
      Plain_chunks ([ valid ], 0.0);
    ]
    (fun client ->
      Convex.query client "tests:status-2000" (`Assoc [])
      |> expect_protocol_error "invalid HTTP status line";
      Convex.query client "tests:status-200X" (`Assoc [])
      |> expect_protocol_error "invalid HTTP status line";
      match Convex.query client "tests:recovered" (`Assoc []) with
      | Ok { value = `Assoc [ ("recovered", `Bool true) ]; logs = [] } -> ()
      | Ok result ->
          fail ("status recovery returned " ^ J.to_string result.value)
      | Error error -> fail (Convex.error_message error))

(* Response framing is the client's trust boundary with the deployment: a
   length it reads wrongly is a length an intermediary chose for it. Each case
   below is followed by a normal request to prove the client is still usable. *)
let test_http_framing () =
  let chunked_body = {|{"status":"success","value":{"framing":"chunked"}}|} in
  let split = String.length chunked_body / 2 in
  let head = String.sub chunked_body 0 split in
  let tail =
    String.sub chunked_body split (String.length chunked_body - split)
  in
  let chunked =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\n\
       Transfer-Encoding: chunked\r\n\
       \r\n\
       %x\r\n\
       %s\r\n\
       %x\r\n\
       %s\r\n\
       0\r\n\
       X-Trailer: seen\r\n\
       \r\n"
      (String.length head) head (String.length tail) tail
  in
  let unframed_body = {|{"status":"success","value":{"framing":"eof"}}|} in
  (* No Content-Length and no chunked encoding: the body ends at end of
     stream, which is exactly what Connection: close asks for. *)
  let unframed =
    "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" ^ unframed_body
  in
  let both_framings =
    "HTTP/1.1 200 OK\r\n\
     Content-Length: 2\r\n\
     Transfer-Encoding: chunked\r\n\
     \r\n"
  in
  let conflicting_lengths =
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nok"
  in
  let hex_length =
    "HTTP/1.1 200 OK\r\nContent-Length: 0x10\r\n\r\nnot sixteen bytes"
  in
  let low_status = "HTTP/1.1 099 Low\r\nContent-Length: 0\r\n\r\n" in
  with_scripted_http ~scheme:"http" ~timeout:2.0
    [
      Plain_chunks ([ chunked ], 0.0);
      Plain_chunks ([ unframed ], 0.0);
      Plain_chunks ([ both_framings ], 0.0);
      Plain_chunks ([ conflicting_lengths ], 0.0);
      Plain_chunks ([ hex_length ], 0.0);
      Plain_chunks ([ low_status ], 0.0);
    ]
    (fun client ->
      (match Convex.query client "tests:chunked" (`Assoc []) with
      | Ok { value = `Assoc [ ("framing", `String "chunked") ]; logs = [] } ->
          ()
      | Ok result ->
          fail ("chunked body decoded to " ^ J.to_string result.value)
      | Error error -> fail (Convex.error_message error));
      (match Convex.query client "tests:unframed" (`Assoc []) with
      | Ok { value = `Assoc [ ("framing", `String "eof") ]; logs = [] } -> ()
      | Ok result ->
          fail ("unframed body decoded to " ^ J.to_string result.value)
      | Error error -> fail (Convex.error_message error));
      Convex.query client "tests:both-framings" (`Assoc [])
      |> expect_protocol_error
           "HTTP response used both Content-Length and chunked encoding";
      Convex.query client "tests:conflicting-lengths" (`Assoc [])
      |> expect_protocol_error "conflicting HTTP Content-Length headers";
      Convex.query client "tests:hex-length" (`Assoc [])
      |> expect_protocol_error "invalid HTTP Content-Length header";
      Convex.query client "tests:low-status" (`Assoc [])
      |> expect_protocol_error "invalid HTTP status line")

(* A line this parser cannot read as a header is not a header it may skip. The
   framing headers in the same block decide how many bytes belong to this
   response, and silently ignoring a line that something else inserted is how a
   client is talked into reading the next response as this one's body. Each
   rejection is followed by a normal request to prove the client recovers. *)
let test_http_header_lines () =
  let body = {|{"status":"success","value":{"recovered":"headers"}}|} in
  let valid =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      (String.length body) body
  in
  let no_colon =
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nNotAHeaderLine\r\n\r\nok"
  in
  let space_in_name =
    "HTTP/1.1 200 OK\r\nContent Length: 2\r\nConnection: close\r\n\r\nok"
  in
  let empty_name = "HTTP/1.1 200 OK\r\n: 2\r\nConnection: close\r\n\r\nok" in
  let folded =
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\tfolded\r\n\r\nok"
  in
  with_scripted_http ~scheme:"http" ~timeout:2.0
    [
      Plain_chunks ([ no_colon ], 0.0);
      Plain_chunks ([ space_in_name ], 0.0);
      Plain_chunks ([ empty_name ], 0.0);
      Plain_chunks ([ folded ], 0.0);
      Plain_chunks ([ valid ], 0.0);
    ]
    (fun client ->
      List.iter
        (fun path ->
          Convex.query client path (`Assoc [])
          |> expect_protocol_error "invalid HTTP header line")
        [
          "tests:no-colon";
          "tests:space-in-name";
          "tests:empty-name";
          "tests:folded";
        ];
      match Convex.query client "tests:header-recovery" (`Assoc []) with
      | Ok { value = `Assoc [ ("recovered", `String "headers") ]; logs = [] } ->
          ()
      | Ok result ->
          fail ("header recovery returned " ^ J.to_string result.value)
      | Error error -> fail (Convex.error_message error))

(* The URL and the auth token both reach request headers verbatim. *)
let test_header_injection () =
  (match Convex.create "http://example.invalid/\r\nX-Injected: 1" with
  | Error (Convex.Protocol_error message)
    when message = "Convex URL must not contain control characters" ->
      ()
  | Error error ->
      fail ("unexpected URL rejection: " ^ Convex.error_message error)
  | Ok client ->
      Convex.close client;
      fail "a deployment URL carrying CRLF must be rejected");
  (* Port 1 is never listening, and no request is sent by any case here. *)
  let client =
    match Convex.create "http://127.0.0.1:1" with
    | Ok value -> value
    | Error error -> fail (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () -> Convex.close client)
    (fun () ->
      (match Convex.set_auth client "token\r\nX-Injected: 1" with
      | Error (Convex.Protocol_error message)
        when message = "auth token must not contain control characters" ->
          ()
      | Error error ->
          fail ("unexpected token rejection: " ^ Convex.error_message error)
      | Ok () -> fail "an auth token carrying CRLF must be rejected");
      (match Convex.set_auth client "ordinary.token.value" with
      | Ok () -> ()
      | Error error ->
          fail ("ordinary token rejected: " ^ Convex.error_message error));
      Convex.query client "" (`Assoc [])
      |> expect_protocol_error "Convex function path is required")

let test_bounded_connect () =
  (* Fill a zero-backlog loopback listener without accepting. Linux then leaves
     later connects pending or rejects them immediately. Both paths must remain
     bounded, and the fixture never depends on an external network. *)
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 0;
  let address, port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) as address -> (address, port)
    | Unix.ADDR_UNIX _ -> assert false
  in
  let fillers =
    List.init 8 (fun _ ->
        let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
        Unix.set_nonblock socket;
        (try Unix.connect socket address
         with
         | Unix.Unix_error
             ( ( Unix.EINPROGRESS | Unix.EAGAIN | Unix.EWOULDBLOCK
               | Unix.ECONNREFUSED ),
               _,
               _ )
         ->
           ());
        socket)
  in
  let client =
    match
      Convex.create ~http_timeout:0.2
        (Printf.sprintf "http://127.0.0.1:%d" port)
    with
    | Ok value -> value
    | Error error -> fail (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () ->
      Convex.close client;
      List.iter Unix.close fillers;
      Unix.close listener)
    (fun () ->
      let started = Unix.gettimeofday () in
      let result = Convex.query client "tests:connect" (`Assoc []) in
      let elapsed = Unix.gettimeofday () -. started in
      if elapsed >= 1.0 then
        fail (Printf.sprintf "bounded connect took %.3f seconds" elapsed);
      match result with
      | Error (Convex.Transport_error { operation = "HTTP query"; _ }) -> ()
      | Error error ->
          fail
            ("expected connect TransportError, got " ^ Convex.error_name error)
      | Ok _ -> fail "saturated listener unexpectedly returned an HTTP result")

(* The handshake accept value is the only thing that ties a 101 response to the
   key this client just generated, so the digest behind it is pinned against
   the vector published in RFC 6455 and against two longer inputs that force
   the padding and multi-block paths. *)
let test_websocket_accept_key () =
  let expect key expected =
    let actual = Convex.websocket_accept_key key in
    if actual <> expected then
      fail ("accept for " ^ key ^ " was " ^ actual ^ ", expected " ^ expected)
  in
  expect "dGhlIHNhbXBsZSBub25jZQ==" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
  expect "AAECAwQFBgcICQoLDA0ODw==" "Bz3qJYTGdOe8gUSpLosEdiLKDrk=";
  expect (String.make 400 'q') "x/cJxGJFIJ0yRehX4NNdx7/d+Y4="

(* Character counts, not byte counts, and nothing that a conforming UTF-8
   decoder must reject may be counted at all. *)
let test_utf8_scalar_count () =
  let expect value expected =
    if Convex.utf8_scalar_count value <> expected then
      fail ("unexpected scalar count for " ^ String.escaped value)
  in
  expect "" (Some 0);
  expect "abc" (Some 3);
  expect "h\xc3\xa9llo" (Some 5);
  expect "\xf0\x9f\x98\x80" (Some 1);
  (* A stray continuation byte, an overlong two byte form, a surrogate half, a
     scalar above U+10FFFF, and a truncated sequence. *)
  expect "\xff" None;
  expect "\x80" None;
  expect "\xc0\xaf" None;
  expect "\xed\xa0\x80" None;
  expect "\xf4\x90\x80\x80" None;
  expect "\xe2\x82" None

(* Build a server frame with explicit control over every field the reader
   validates, so a fixture can describe a frame the protocol forbids.
   [length_form] is 0 for the minimal encoding, or 1, 2, or 8 to force the
   seven bit, sixteen bit, or sixty-four bit length field. *)
let frame_bytes ?(fin = true) ?(rsv = 0) ?(masked = false) ?(length_form = 0)
    opcode payload =
  let length = String.length payload in
  let buffer = Buffer.create (length + 14) in
  Buffer.add_char buffer
    (Char.chr (((if fin then 0x80 else 0) lor (rsv lsl 4) lor opcode) land 255));
  let mask_bit = if masked then 0x80 else 0 in
  let form =
    if length_form <> 0 then length_form
    else if length < 126 then 1
    else if length <= 65535 then 2
    else 8
  in
  (match form with
  | 1 -> Buffer.add_char buffer (Char.chr (mask_bit lor length))
  | 2 ->
      Buffer.add_char buffer (Char.chr (mask_bit lor 126));
      Buffer.add_char buffer (Char.chr ((length lsr 8) land 255));
      Buffer.add_char buffer (Char.chr (length land 255))
  | _ ->
      Buffer.add_char buffer (Char.chr (mask_bit lor 127));
      for index = 7 downto 0 do
        Buffer.add_char buffer (Char.chr ((length lsr (index * 8)) land 255))
      done);
  if masked then (
    let key = "\x01\x02\x03\x04" in
    Buffer.add_string buffer key;
    String.iteri
      (fun index char ->
        Buffer.add_char buffer
          (Char.chr (Char.code char lxor Char.code key.[index mod 4])))
      payload)
  else Buffer.add_string buffer payload;
  Buffer.contents buffer

let text_frame payload = frame_bytes 1 payload

(* The client masks its frames, so the fixture has to unmask them before it can
   tell a Connect from a ModifyQuerySet. Only the length is used here. *)
let read_client_frame input =
  let header = really_input_string input 2 in
  let second = Char.code header.[1] in
  let masked = second land 0x80 <> 0 in
  let short_length = second land 0x7f in
  let length =
    if short_length < 126 then short_length
    else if short_length = 126 then
      let bytes = really_input_string input 2 in
      (Char.code bytes.[0] lsl 8) lor Char.code bytes.[1]
    else fail "fixture does not accept 64-bit client frames"
  in
  if masked then ignore (really_input_string input 4);
  ignore (really_input_string input length)

let read_handshake_key input =
  let key = ref "" in
  let prefix = "sec-websocket-key:" in
  let rec loop () =
    let line = input_line input in
    if line = "\r" then ()
    else (
      if String.starts_with ~prefix (String.lowercase_ascii line) then
        key :=
          String.trim
            (String.sub line (String.length prefix)
               (String.length line - String.length prefix));
      loop ())
  in
  loop ();
  !key

let accept_response key =
  "HTTP/1.1 101 Switching Protocols\r\n\
   Upgrade: websocket\r\n\
   Connection: Upgrade\r\n\
   Sec-WebSocket-Accept: " ^ Convex.websocket_accept_key key ^ "\r\n\r\n"

(* [response] receives the client's Sec-WebSocket-Key so a turn can answer with
   a genuinely correct accept value, a deliberately wrong one, or a response
   that spells the required headers differently. *)
type live_turn = {
  response : string -> string;
  client_frames : int;
  send : string list;
  linger : float;
}

let accepted_turn ?(linger = 0.3) send =
  { response = accept_response; client_frames = 2; send; linger }

let serving_turn ?(linger = 0.4) response send =
  { response; client_frames = 2; send; linger }

let rejected_turn raw =
  { response = (fun _ -> raw); client_frames = 0; send = []; linger = 0.0 }

(* Serve a scripted sequence of WebSocket connections on a loopback port. Each
   turn answers one handshake, optionally consumes the Connect and
   ModifyQuerySet frames the client always sends, writes raw bytes, and then
   closes. The accept loop polls so a script with more turns than the client
   actually needs cannot leave this thread parked forever. *)
let with_live_fixture turns check =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener (List.length turns + 1);
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let stop = ref false in
  let thread =
    Thread.create
      (fun () ->
        Fun.protect
          ~finally:(fun () -> Unix.close listener)
          (fun () ->
            let rec accept_next () =
              if !stop then None
              else
                let ready, _, _ = Unix.select [ listener ] [] [] 0.25 in
                if ready = [] then accept_next ()
                else Some (fst (Unix.accept listener))
            in
            let rec serve = function
              | [] -> ()
              | turn :: rest -> (
                  match accept_next () with
                  | None -> ()
                  | Some socket ->
                      let input = Unix.in_channel_of_descr socket in
                      let output = Unix.out_channel_of_descr socket in
                      Fun.protect
                        ~finally:(fun () ->
                          close_in_noerr input;
                          close_out_noerr output)
                        (fun () ->
                          try
                            let key = read_handshake_key input in
                            output_string output (turn.response key);
                            flush output;
                            for _ = 1 to turn.client_frames do
                              read_client_frame input
                            done;
                            List.iter
                              (fun frame ->
                                output_string output frame;
                                flush output)
                              turn.send;
                            Thread.delay turn.linger
                          with End_of_file | Sys_error _ | Failure _ -> ());
                      serve rest)
            in
            serve turns))
      ()
  in
  let client =
    match Convex.create (Printf.sprintf "http://127.0.0.1:%d" port) with
    | Ok value -> value
    | Error error -> fail (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () ->
      Convex.close client;
      stop := true;
      Thread.join thread)
    (fun () -> check client)

let live_transition ?(query_id = 0) value =
  Printf.sprintf
    {|{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":%d,"value":%s}]}|}
    query_id value

let subscribe_live client =
  match Convex.subscribe client "tests:live" (`Assoc []) with
  | Ok subscription -> subscription
  | Error error -> fail (Convex.error_message error)

let next_live label subscription timeout =
  match Convex.subscription_next subscription timeout with
  | Ok (Some update) -> update
  | Ok None -> fail (label ^ ": no Live update arrived in time")
  | Error error -> fail (label ^ ": " ^ Convex.error_message error)

let expect_live_value label subscription timeout expected =
  let update = next_live label subscription timeout in
  match (update.error, update.value) with
  | Some error, _ ->
      fail (label ^ ": unexpected error " ^ Convex.error_message error)
  | None, Some value when J.equal value expected -> ()
  | None, Some value -> fail (label ^ ": value was " ^ J.to_string value)
  | None, None -> fail (label ^ ": update omitted a value")

let expect_live_protocol_error label subscription expected =
  let update = next_live label subscription 10.0 in
  match update.error with
  | Some (Convex.Protocol_error message) when message = expected -> ()
  | Some (Convex.Protocol_error message) ->
      fail (label ^ ": protocol error was " ^ message)
  | Some error ->
      fail (label ^ ": expected ProtocolError, got " ^ Convex.error_name error)
  | None -> fail (label ^ ": expected a protocol error, got a value")

let contains haystack needle =
  let limit = String.length haystack - String.length needle in
  let rec search index =
    if index > limit then false
    else if String.sub haystack index (String.length needle) = needle then true
    else search (index + 1)
  in
  String.length needle <= String.length haystack && search 0

let expect_live_error_containing label subscription expected =
  let update = next_live label subscription 10.0 in
  match update.error with
  | Some error when contains (Convex.error_message error) expected -> ()
  | Some error -> fail (label ^ ": error was " ^ Convex.error_message error)
  | None -> fail (label ^ ": expected an error, got a value")

let good_value = `Assoc [ ("count", `Int 0) ]
let good_json = live_transition {|{"count":0}|}
let good_transition = text_frame good_json

(* A 101 alone does not prove the peer answered this handshake. Each rejected
   response below is followed by a correct connection so the client is shown to
   refuse the response without stranding the subscription. *)
let test_websocket_handshake_validation () =
  let reject_then_recover label response =
    with_live_fixture
      [ rejected_turn response; accepted_turn [ good_transition ] ]
      (fun client ->
        let subscription = subscribe_live client in
        expect_live_value label subscription 15.0 good_value)
  in
  let wrong_accept =
    Convex.websocket_accept_key "AAECAwQFBgcICQoLDA0ODw=="
  in
  reject_then_recover "non-101 handshake"
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  reject_then_recover "wrong Upgrade target"
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: h2c\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Accept: ignored\r\n\r\n";
  reject_then_recover "Connection without the Upgrade token"
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: keep-alive\r\n\
     Sec-WebSocket-Accept: ignored\r\n\r\n";
  reject_then_recover "absent accept"
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\r\n";
  reject_then_recover "accept for another key"
    ("HTTP/1.1 101 Switching Protocols\r\n\
      Upgrade: websocket\r\n\
      Connection: Upgrade\r\n\
      Sec-WebSocket-Accept: " ^ wrong_accept ^ "\r\n\r\n");
  reject_then_recover "unrequested extension"
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Extensions: permessage-deflate\r\n\
     Sec-WebSocket-Accept: ignored\r\n\r\n";
  reject_then_recover "framed 101"
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Content-Length: 0\r\n\r\n"

(* The positive half of the same rule. Header names and the Upgrade value are
   case insensitive and Connection is a token list, so a correct server that
   spells any of that differently must still be accepted; a validator that
   compared whole values verbatim would reject a conforming deployment. *)
let test_websocket_handshake_accepts_case_and_tokens () =
  let canonical = accepted_turn [ good_transition ] in
  let spelled_differently =
    serving_turn
      (fun key ->
        "HTTP/1.1 101 Switching Protocols\r\n\
         upgrade: WebSocket\r\n\
         connection: keep-alive, UPGRADE\r\n\
         SEC-WEBSOCKET-ACCEPT: " ^ Convex.websocket_accept_key key ^ "\r\n\r\n")
      [ good_transition ]
  in
  List.iter
    (fun turn ->
      with_live_fixture [ turn ] (fun client ->
          let subscription = subscribe_live client in
          expect_live_value "accepted handshake" subscription 15.0 good_value))
    [ canonical; spelled_differently ]

let test_websocket_frame_validation () =
  let reject_then_recover label frames expected =
    with_live_fixture
      [
        { response = accept_response; client_frames = 2; send = frames; linger = 0.4 };
        accepted_turn [ good_transition ];
      ]
      (fun client ->
        let subscription = subscribe_live client in
        expect_live_protocol_error label subscription expected;
        expect_live_value (label ^ " recovery") subscription 15.0 good_value)
  in
  reject_then_recover "reserved bit"
    [ frame_bytes ~rsv:4 1 "{}" ]
    "WebSocket frame set a reserved bit";
  reject_then_recover "masked server frame"
    [ frame_bytes ~masked:true 1 "{}" ]
    "WebSocket server frame was masked";
  reject_then_recover "reserved opcode" [ frame_bytes 3 "" ]
    "WebSocket frame used a reserved opcode";
  reject_then_recover "fragmented control frame"
    [ frame_bytes ~fin:false 9 "x" ]
    "WebSocket control frame was fragmented";
  reject_then_recover "oversized control frame"
    [ frame_bytes 9 (String.make 126 'x') ]
    "WebSocket control frame exceeds 125 bytes";
  reject_then_recover "non-minimal 16-bit length"
    [ frame_bytes ~length_form:2 1 "{}" ]
    "WebSocket frame length was not minimally encoded";
  reject_then_recover "non-minimal 64-bit length"
    [ frame_bytes ~length_form:8 1 (String.make 200 'x') ]
    "WebSocket frame length was not minimally encoded";
  reject_then_recover "one byte close payload" [ frame_bytes 8 "\003" ]
    "WebSocket close frame carried a one byte payload";
  reject_then_recover "invalid close code" [ frame_bytes 8 "\003\237" ]
    "WebSocket close frame used an invalid code";
  reject_then_recover "close reason that is not UTF-8"
    [ frame_bytes 8 "\003\232\255" ]
    "WebSocket close reason was not valid UTF-8";
  reject_then_recover "text that is not UTF-8" [ frame_bytes 1 "\255\254" ]
    "WebSocket text message was not valid UTF-8";
  reject_then_recover "unexpected continuation" [ frame_bytes 0 "abc" ]
    "unexpected WebSocket continuation";
  reject_then_recover "interleaved data frame"
    [ frame_bytes ~fin:false 1 "{"; frame_bytes 1 "{}" ]
    "WebSocket data frame interrupted a fragmented message";
  reject_then_recover "binary opcode" [ frame_bytes 2 "\000" ]
    "unsupported WebSocket opcode"

(* Each of these frames is inside the per-frame limit. Together they are not,
   and the limit that matters is the one on the assembled message: without it a
   peer can send as many legal frames as it likes and choose how much memory
   the accumulating buffer takes. *)
let test_websocket_fragment_budget () =
  let megabyte = String.make (1024 * 1024) 'a' in
  with_live_fixture
    [
      {
        response = accept_response;
        client_frames = 2;
        send =
          [
            frame_bytes ~fin:false 1 (String.make (1536 * 1024) 'a');
            frame_bytes ~fin:false 0 megabyte;
          ];
        linger = 0.4;
      };
      accepted_turn [ good_transition ];
    ]
    (fun client ->
      let subscription = subscribe_live client in
      expect_live_protocol_error "fragment budget" subscription
        "WebSocket message exceeds 2097152 bytes";
      expect_live_value "fragment budget recovery" subscription 15.0 good_value)

(* Control frames still work, and a fragmented text message that stays inside
   the limit is reassembled rather than rejected. *)
let test_websocket_fragmented_message () =
  let head = String.sub good_json 0 40 in
  let tail = String.sub good_json 40 (String.length good_json - 40) in
  with_live_fixture
    [
      {
        response = accept_response;
        client_frames = 2;
        send =
          [
            frame_bytes 9 "ping";
            frame_bytes ~fin:false 1 head;
            frame_bytes 0 tail;
          ];
        linger = 0.5;
      };
    ]
    (fun client ->
      let subscription = subscribe_live client in
      expect_live_value "fragmented transition" subscription 15.0 good_value)

(* A query ID this client never issued must not be recorded as delivered
   state. Retaining it would grow with every such message and would answer for
   a real subscription that later reuses the number. *)
let test_unknown_query_id () =
  with_live_fixture
    [
      {
        response = accept_response;
        client_frames = 2;
        send = [ text_frame (live_transition ~query_id:99 {|{"count":7}|}) ];
        linger = 0.4;
      };
      accepted_turn [ good_transition ];
    ]
    (fun client ->
      let subscription = subscribe_live client in
      expect_live_error_containing "unknown query id" subscription
        "Transition names unknown query 99";
      expect_live_value "unknown query id recovery" subscription 15.0
        good_value)

(* Five refused handshakes drive the reconnect delay up to seconds. The
   connection after them is healthy, so the delay that follows *it* must start
   again from the floor rather than inherit the old maximum. *)
let test_backoff_resets_after_handshake () =
  let refusal =
    "HTTP/1.1 503 Service Unavailable\r\n\
     Content-Length: 0\r\n\
     Connection: close\r\n\r\n"
  in
  let second_value = `Assoc [ ("count", `Int 1) ] in
  with_live_fixture
    [
      rejected_turn refusal;
      rejected_turn refusal;
      rejected_turn refusal;
      rejected_turn refusal;
      rejected_turn refusal;
      {
        response = accept_response;
        client_frames = 2;
        send = [ good_transition ];
        linger = 0.2;
      };
      {
        response = accept_response;
        client_frames = 2;
        send = [ text_frame (live_transition {|{"count":1}|}) ];
        linger = 0.3;
      };
    ]
    (fun client ->
      let subscription = subscribe_live client in
      expect_live_value "healthy connection" subscription 20.0 good_value;
      (* The fixture closes the healthy connection, which the client reports
         before it schedules the next attempt. *)
      let _ = next_live "healthy close" subscription 10.0 in
      let started = Unix.gettimeofday () in
      expect_live_value "reconnect after reset" subscription 10.0 second_value;
      let elapsed = Unix.gettimeofday () -. started in
      (* Without the reset the delay in force here would be 3.2 seconds. *)
      if elapsed >= 1.5 then
        fail
          (Printf.sprintf "reconnect after a healthy connection took %.3fs"
             elapsed))

let test_transport_error () =
  (* Reserve an ephemeral loopback port, then release it before the request.
     The immediate connection attempt deterministically reaches no listener. *)
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  Unix.close socket;
  let client =
    match Convex.create (Printf.sprintf "http://127.0.0.1:%d" port) with
    | Ok value -> value
    | Error error -> fail (Convex.error_message error)
  in
  Fun.protect
    ~finally:(fun () -> Convex.close client)
    (fun () ->
      match Convex.query client "tests:fixture" (`Assoc []) with
      | Error (Convex.Transport_error { operation = "HTTP query"; _ }) -> ()
      | Error error ->
          fail
            ("expected TransportError, got " ^ Convex.error_name error ^ ": "
           ^ Convex.error_message error)
      | Ok _ ->
          fail "connection to a closed fixture port unexpectedly succeeded")

let () =
  (match Convex.parse_integral_int64 (`Float 0.0) with
  | Ok 0L -> ()
  | _ -> fail "0.0 should be integral");
  (match Convex.parse_integral_int64 (`Float 1.0) with
  | Ok 1L -> ()
  | _ -> fail "1.0 should be integral");
  expect_error "count must be mathematically integral"
    (Convex.parse_integral_int64 (`Float 1.5));
  expect_error "count must be a JSON number"
    (Convex.parse_integral_int64 (`String "1"));
  expect_error "count is outside the int64 range"
    (Convex.parse_integral_int64 (`Intlit "9223372036854775808"));
  test_websocket_accept_key ();
  test_utf8_scalar_count ();
  test_http_absolute_deadlines ();
  test_malformed_status_recovery ();
  test_http_framing ();
  test_http_header_lines ();
  test_header_injection ();
  test_bounded_connect ();
  test_websocket_handshake_accepts_case_and_tokens ();
  test_websocket_handshake_validation ();
  test_websocket_frame_validation ();
  test_websocket_fragment_budget ();
  test_websocket_fragmented_message ();
  test_unknown_query_id ();
  test_backoff_resets_after_handshake ();
  with_http_response 200
    {|{"status":"success","value":{"ok":true},"logLines":["fixture"]}|}
    (function
    | Ok { value = `Assoc [ ("ok", `Bool true) ]; logs = [ "fixture" ] } -> ()
    | Ok result -> fail ("unexpected success result " ^ J.to_string result.value)
    | Error error -> fail (Convex.error_message error));
  with_http_response 200 {|{"status":"success","value":{"ok":true}}|} (function
    | Ok { value = `Assoc [ ("ok", `Bool true) ]; logs = [] } -> ()
    | Ok result ->
        fail ("absent logLines changed result " ^ J.to_string result.value)
    | Error error -> fail (Convex.error_message error));
  with_http_response 200 {|{"status":"success","value":null,"logLines":null}|}
    (expect_protocol_error "field logLines must be an array");
  with_http_response 200
    {|{"status":"success","value":null,"logLines":["ok",7]}|}
    (expect_protocol_error "field logLines must contain strings");
  with_http_response 200 {|{"status":"success","value":null}|} (function
    | Ok { value = `Null; logs = [] } -> ()
    | Ok _ -> fail "JSON null is a valid Convex value"
    | Error error -> fail (Convex.error_message error));
  with_http_response 200 {|{"status":"success","logLines":[]}|}
    (expect_protocol_error "success response omitted value");
  with_http_response 503
    {|{"status":"success","value":{"ok":true},"logLines":[]}|} (function
    | Error
        (Convex.Http_error
           {
             operation = "query";
             status_code = 503;
             message = "unsuccessful HTTP status carried a success response";
           }) ->
        ()
    | Error error ->
        fail
          ("expected HttpError for 503 success envelope, got "
         ^ Convex.error_name error ^ ": " ^ Convex.error_message error)
    | Ok _ -> fail "HTTP 503 success envelope must not return success");
  with_http_response 560
    {|{"status":"error","errorMessage":"expected failure","errorData":{"code":"EXPECTED_560"},"logLines":["before failure"]}|}
    (function
    | Error
        (Convex.Function_error
           {
             operation = "query";
             message = "expected failure";
             data = Some (`Assoc [ ("code", `String "EXPECTED_560") ]);
             logs = [ "before failure" ];
           }) ->
        ()
    | Error error ->
        fail
          ("expected structured FunctionError, got " ^ Convex.error_name error
         ^ ": " ^ Convex.error_message error)
    | Ok _ -> fail "HTTP 560 function failure must not return success");
  with_http_response 560 {|{"status":"error","errorMessage":"plain failure"}|}
    (function
    | Error
        (Convex.Function_error
           {
             operation = "query";
             message = "plain failure";
             data = None;
             logs = [];
           }) ->
        ()
    | Error error ->
        fail
          ("expected FunctionError without optional fields, got "
         ^ Convex.error_name error ^ ": " ^ Convex.error_message error)
    | Ok _ -> fail "function failure without optional fields returned success");
  with_http_response 560 {|{"status":"error","errorMessage":7,"logLines":[]}|}
    (expect_protocol_error "field errorMessage must be a string");
  with_http_response 560
    {|{"status":"error","errorMessage":"bad logs","logLines":null}|}
    (expect_protocol_error "field logLines must be an array");
  with_http_response 200 {|{"status":1,"value":null}|}
    (expect_protocol_error "field status must be a string");
  with_http_response 200 {|{"status":"unknown","value":null}|}
    (expect_protocol_error "HTTP 200 response has unknown status unknown");
  with_http_response 200 "[]"
    (expect_protocol_error "HTTP 200 response body must be a JSON object");
  with_http_response 200 {|{"status":"success","value":null,"logLines":{}}|}
    (expect_protocol_error "field logLines must be an array");
  with_http_response 200 {|{"status":"error","errorData":null}|}
    (expect_protocol_error "response omitted errorMessage");
  with_http_response 200 "not-json"
    (expect_protocol_error "HTTP 200 response body was not valid JSON");
  with_http_response 503 "not-json" (function
    | Error
        (Convex.Http_error
           {
             operation = "query";
             status_code = 503;
             message = "response body was not valid JSON";
           }) ->
        ()
    | Error error ->
        fail
          ("expected HttpError for invalid 503 body, got "
         ^ Convex.error_name error ^ ": " ^ Convex.error_message error)
    | Ok _ -> fail "invalid HTTP 503 body returned success");
  with_http_response 503 "[]" (function
    | Error
        (Convex.Http_error
           {
             operation = "query";
             status_code = 503;
             message = "response body was not a JSON object";
           }) ->
        ()
    | Error error ->
        fail
          ("expected HttpError for non-object 503 body, got "
         ^ Convex.error_name error ^ ": " ^ Convex.error_message error)
    | Ok _ -> fail "non-object HTTP 503 body returned success");
  test_transport_error ();
  print_endline
    "PASS OCaml local HTTP, WebSocket, protocol, and numeric fixtures"
