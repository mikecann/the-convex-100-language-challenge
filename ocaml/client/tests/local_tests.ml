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
  test_http_absolute_deadlines ();
  test_malformed_status_recovery ();
  test_http_framing ();
  test_header_injection ();
  test_bounded_connect ();
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
  print_endline "PASS OCaml local HTTP, protocol, and numeric fixtures"
