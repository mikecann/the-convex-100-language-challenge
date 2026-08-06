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
  with_http_response 200
    {|{"status":"success","value":{"ok":true},"logLines":["fixture"]}|}
    (function
    | Ok { value = `Assoc [ ("ok", `Bool true) ]; logs = [ "fixture" ] } -> ()
    | Ok result -> fail ("unexpected success result " ^ J.to_string result.value)
    | Error error -> fail (Convex.error_message error));
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
  with_http_response 200 {|{"status":1,"value":null}|}
    (expect_protocol_error "field status must be a string");
  with_http_response 200 {|{"status":"success","value":null,"logLines":{}}|}
    (expect_protocol_error "field logLines must be an array");
  with_http_response 200 {|{"status":"error","errorData":null}|}
    (expect_protocol_error "response omitted errorMessage");
  with_http_response 200 "not-json"
    (expect_protocol_error "HTTP 200 response body was not valid JSON");
  test_transport_error ();
  print_endline "PASS OCaml local HTTP, protocol, and numeric fixtures"
