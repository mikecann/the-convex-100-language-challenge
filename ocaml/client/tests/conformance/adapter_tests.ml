module J = Yojson.Safe

let fail message = raise (Failure message)

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match member name json with Some (`String value) -> Some value | _ -> None

let require condition message = if not condition then fail message

let require_string name expected json =
  require
    (string_member name json = Some expected)
    ("expected " ^ name ^ "=" ^ expected ^ " in " ^ J.to_string json)

let require_no_id json =
  require
    (member "id" json = None)
    ("malformed command response must omit id: " ^ J.to_string json)

let require_error ?id ?subscription_id name message json =
  require_string "type"
    (match subscription_id with Some _ -> "subscription" | None -> "error")
    json;
  (match id with
  | Some value -> require_string "id" value json
  | None -> require_no_id json);
  (match subscription_id with
  | Some value -> require_string "subscriptionId" value json
  | None -> ());
  match member "error" json with
  | Some error ->
      require_string "name" name error;
      require_string "message" message error
  | None -> fail ("error event omitted error object: " ^ J.to_string json)

let environment_with name value =
  let prefix = name ^ "=" in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun entry ->
           not
             (String.length entry >= String.length prefix
             && String.sub entry 0 (String.length prefix) = prefix))
  in
  Array.of_list ((prefix ^ value) :: inherited)

type adapter_process = { pid : int; input : out_channel; output : in_channel }

let start_adapter executable url =
  let child_read, parent_write = Unix.pipe () in
  let parent_read, child_write = Unix.pipe () in
  let pid =
    Unix.create_process_env executable [| executable |]
      (environment_with "CONVEX_URL" url)
      child_read child_write Unix.stderr
  in
  Unix.close child_read;
  Unix.close child_write;
  {
    pid;
    input = Unix.out_channel_of_descr parent_write;
    output = Unix.in_channel_of_descr parent_read;
  }

let send process json =
  output_string process.input (json ^ "\n");
  flush process.input

let receive process = J.from_string (input_line process.output)

let finish process =
  close_out_noerr process.input;
  close_in_noerr process.output;
  match snd (Unix.waitpid [] process.pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      fail ("adapter exited with status " ^ string_of_int code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      fail ("adapter stopped on signal " ^ string_of_int signal)

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

type http_action =
  | Respond of int * string
  | Raw_response of string
  | Close_early
  | Timeout

let start_http_fixture actions =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 4;
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let thread =
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
                ignore (read_http_request input);
                (match action with
                | Respond (status, body) ->
                    Printf.fprintf output
                      "HTTP/1.1 %d fixture\r\n\
                       Content-Type: application/json\r\n\
                       Content-Length: %d\r\n\
                       Connection: close\r\n\
                       \r\n\
                       %s"
                      status (String.length body) body;
                    flush output
                | Raw_response response ->
                    output_string output response;
                    flush output
                | Close_early -> ()
                | Timeout -> Thread.delay 30.25);
                close_in_noerr input;
                close_out_noerr output)
              actions))
      ()
  in
  (port, thread)

let test_serialized_http_and_validation executable =
  let success =
    {|{"status":"success","value":{"ok":true},"logLines":["normal"]}|}
  in
  let function_error =
    {|{"status":"error","errorMessage":"expected failure","errorData":{"code":"EXPECTED_560"},"logLines":["before failure"]}|}
  in
  let false_success =
    {|{"status":"success","value":{"ok":true},"logLines":[]}|}
  in
  let absent_logs = {|{"status":"success","value":{"logs":"absent"}}|} in
  let null_logs = {|{"status":"success","value":null,"logLines":null}|} in
  let wrong_log_element =
    {|{"status":"success","value":null,"logLines":["ok",7]}|}
  in
  let status_wrong_type = {|{"status":1,"value":null}|} in
  let valid_after_close =
    {|{"status":"success","value":{"recovered":"close"},"logLines":[]}|}
  in
  let valid_after_timeout =
    {|{"status":"success","value":{"recovered":"timeout"},"logLines":[]}|}
  in
  let valid_after_status =
    {|{"status":"success","value":{"recovered":"status"},"logLines":[]}|}
  in
  let malformed_status suffix =
    "HTTP/1.1 " ^ suffix
    ^ " Bad\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  in
  let port, fixture =
    start_http_fixture
      [
        Respond (200, success);
        Respond (200, absent_logs);
        Respond (200, null_logs);
        Respond (200, wrong_log_element);
        Respond (560, function_error);
        Respond (503, false_success);
        Respond (200, status_wrong_type);
        Respond (200, "[]");
        Close_early;
        Respond (200, valid_after_close);
        Timeout;
        Respond (200, valid_after_timeout);
        Raw_response (malformed_status "2000");
        Raw_response (malformed_status "200X");
        Respond (200, valid_after_status);
      ]
  in
  let process =
    start_adapter executable (Printf.sprintf "http://127.0.0.1:%d" port)
  in
  List.iter (send process)
    [
      "{";
      {|{"protocolVersion":1,"op":"hello"}|};
      {|{"protocolVersion":1,"id":7,"op":"hello"}|};
      {|{"protocolVersion":1,"id":"typed","op":7}|};
      {|{"protocolVersion":1,"id":"hello-1","op":"hello"}|};
      {|{"id":"query-1","op":"query","path":"tests:ok","args":{}}|};
      {|{"id":"query-absent-logs","op":"query","path":"tests:absentLogs","args":{}}|};
      {|{"id":"query-null-logs","op":"query","path":"tests:nullLogs","args":{}}|};
      {|{"id":"query-wrong-log-element","op":"query","path":"tests:wrongLogElement","args":{}}|};
      {|{"id":"query-function","op":"query","path":"tests:fail","args":{}}|};
      {|{"id":"query-http","op":"query","path":"tests:falseSuccess","args":{}}|};
      {|{"id":"query-status-type","op":"query","path":"tests:statusType","args":{}}|};
      {|{"id":"query-root","op":"query","path":"tests:root","args":{}}|};
      {|{"id":"query-close","op":"query","path":"tests:close","args":{}}|};
      {|{"id":"query-after-close","op":"query","path":"tests:afterClose","args":{}}|};
      {|{"id":"query-timeout","op":"query","path":"tests:timeout","args":{}}|};
      {|{"id":"query-after-timeout","op":"query","path":"tests:afterTimeout","args":{}}|};
      {|{"id":"query-status-2000","op":"query","path":"tests:status2000","args":{}}|};
      {|{"id":"query-status-200X","op":"query","path":"tests:status200X","args":{}}|};
      {|{"id":"query-status-recovered","op":"query","path":"tests:statusRecovered","args":{}}|};
      {|{"id":"close-1","op":"close"}|};
    ];
  close_out process.input;
  let events = List.init 21 (fun _ -> receive process) in
  let ( malformed,
        missing_id,
        wrong_id,
        wrong_op,
        ready,
        result,
        absent_logs_result,
        null_logs_error,
        wrong_log_element_error,
        function_error_event,
        http_error_event,
        status_type_error,
        root_error,
        close_error,
        after_close_result,
        timeout_error,
        after_timeout_result,
        malformed_status_long,
        malformed_status_suffix,
        status_recovery_result,
        closed ) =
    match events with
    | [ a; b; c; d; e; f; g; h; i; j; k; l; m; n; o; p; q; r; s; t; u ] ->
        (a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u)
    | _ -> assert false
  in
  require_error "ProtocolError" "malformed adapter command" malformed;
  require_error "ProtocolError" "adapter command omitted id" missing_id;
  require_error "ProtocolError" "adapter command id must be a string" wrong_id;
  require_error ~id:"typed" "ProtocolError"
    "adapter command op must be a string" wrong_op;
  require_string "type" "ready" ready;
  require_string "id" "hello-1" ready;
  require_string "type" "result" result;
  require_string "id" "query-1" result;
  require
    (member "value" result = Some (`Assoc [ ("ok", `Bool true) ]))
    ("normal result lost its value: " ^ J.to_string result);
  require
    (member "logs" result = Some (`List [ `String "normal" ]))
    ("normal result lost its logs: " ^ J.to_string result);
  require_string "type" "result" absent_logs_result;
  require_string "id" "query-absent-logs" absent_logs_result;
  require
    (member "logs" absent_logs_result = None)
    ("absent logs must stay omitted: " ^ J.to_string absent_logs_result);
  require_error ~id:"query-null-logs" "ProtocolError"
    "field logLines must be an array" null_logs_error;
  require_error ~id:"query-wrong-log-element" "ProtocolError"
    "field logLines must contain strings" wrong_log_element_error;
  require_error ~id:"query-function" "FunctionError" "expected failure"
    function_error_event;
  require
    (member "logs" function_error_event
    = Some (`List [ `String "before failure" ]))
    ("function error lost logs: " ^ J.to_string function_error_event);
  require
    (match member "error" function_error_event with
    | Some body ->
        member "data" body = Some (`Assoc [ ("code", `String "EXPECTED_560") ])
    | None -> false)
    ("function error lost structured data: " ^ J.to_string function_error_event);
  require_error ~id:"query-http" "HttpError"
    "HTTP query returned 503: unsuccessful HTTP status carried a success \
     response"
    http_error_event;
  require_error ~id:"query-status-type" "ProtocolError"
    "field status must be a string" status_type_error;
  require_error ~id:"query-root" "ProtocolError"
    "HTTP 200 response body must be a JSON object" root_error;
  require_error ~id:"query-close" "TransportError"
    "HTTP query: connection closed before the response completed" close_error;
  require_string "type" "result" after_close_result;
  require_string "id" "query-after-close" after_close_result;
  require
    (member "value" after_close_result
    = Some (`Assoc [ ("recovered", `String "close") ]))
    ("adapter did not recover after early close: "
    ^ J.to_string after_close_result);
  require_error ~id:"query-timeout" "TransportError"
    "HTTP query: timed out while waiting for the response" timeout_error;
  require_string "type" "result" after_timeout_result;
  require_string "id" "query-after-timeout" after_timeout_result;
  require
    (member "value" after_timeout_result
    = Some (`Assoc [ ("recovered", `String "timeout") ]))
    ("adapter did not recover after timeout: "
    ^ J.to_string after_timeout_result);
  require_error ~id:"query-status-2000" "ProtocolError"
    "invalid HTTP status line" malformed_status_long;
  require_error ~id:"query-status-200X" "ProtocolError"
    "invalid HTTP status line" malformed_status_suffix;
  require_string "type" "result" status_recovery_result;
  require_string "id" "query-status-recovered" status_recovery_result;
  require
    (member "value" status_recovery_result
    = Some (`Assoc [ ("recovered", `String "status") ]))
    ("adapter did not recover after malformed status: "
    ^ J.to_string status_recovery_result);
  require_string "type" "closed" closed;
  require_string "id" "close-1" closed;
  close_in_noerr process.output;
  (match snd (Unix.waitpid [] process.pid) with
  | Unix.WEXITED 0 -> ()
  | _ -> fail "serialized adapter validation process did not exit cleanly");
  Thread.join fixture

let read_websocket_frame input =
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
  let mask = if masked then Some (really_input_string input 4) else None in
  let payload = Bytes.of_string (really_input_string input length) in
  (match mask with
  | Some key ->
      for index = 0 to length - 1 do
        Bytes.set payload index
          (Char.chr
             (Char.code (Bytes.get payload index)
             lxor Char.code key.[index mod 4]))
      done
  | None -> ());
  Bytes.to_string payload

let write_websocket_text output payload =
  let length = String.length payload in
  output_char output (Char.chr 0x81);
  if length < 126 then output_char output (Char.chr length)
  else if length <= 65535 then (
    output_char output (Char.chr 126);
    output_char output (Char.chr (length lsr 8));
    output_char output (Char.chr (length land 255)))
  else fail "fixture payload is too large";
  output_string output payload;
  flush output

let start_live_fixture () =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 1;
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let thread =
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
            let rec headers () = if input_line input <> "\r" then headers () in
            headers ();
            output_string output
              "HTTP/1.1 101 Switching Protocols\r\n\
               Upgrade: websocket\r\n\
               Connection: Upgrade\r\n\
               \r\n";
            flush output;
            ignore (read_websocket_frame input);
            ignore (read_websocket_frame input);
            write_websocket_text output
              {|{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":"live fixture failed","errorData":{"code":"LIVE_FAILED"},"logLines":["live log"]}]}|};
            (* Begin another frame, then stall before its length byte. The
               socket owner must abandon this partial frame when the adapter
               asks it to retire the connection. *)
            output_char output (Char.chr 0x81);
            flush output;
            Thread.delay 2.0))
      ()
  in
  (port, thread)

let test_serialized_subscription_error executable =
  let port, fixture = start_live_fixture () in
  let process =
    start_adapter executable (Printf.sprintf "http://127.0.0.1:%d" port)
  in
  send process
    {|{"id":"subscribe-1","op":"subscribe","subscriptionId":"room-1","path":"tests:live","args":{}}|};
  let ack = receive process in
  require_string "type" "ack" ack;
  require_string "id" "subscribe-1" ack;
  let event = receive process in
  require_error ~subscription_id:"room-1" "FunctionError" "live fixture failed"
    event;
  require
    (member "logs" event = Some (`List [ `String "live log" ]))
    ("subscription error lost logs: " ^ J.to_string event);
  require
    (match member "error" event with
    | Some body ->
        member "data" body = Some (`Assoc [ ("code", `String "LIVE_FAILED") ])
    | None -> false)
    ("subscription error lost structured data: " ^ J.to_string event);
  send process {|{"id":"disconnect-live","op":"debugDisconnect"}|};
  let disconnected = receive process in
  require_string "type" "ack" disconnected;
  require_string "id" "disconnect-live" disconnected;
  send process {|{"id":"close-live","op":"close"}|};
  let closed = receive process in
  require_string "type" "closed" closed;
  require_string "id" "close-live" closed;
  finish process;
  Thread.join fixture

(* A stalled expectation would otherwise hang the Docker build rather than
   fail it, so every blocking read below runs under a hard deadline. *)
let watchdog seconds pid =
  let disarmed = ref false in
  let thread =
    Thread.create
      (fun () ->
        let rec wait remaining =
          if remaining > 0.0 && not !disarmed then (
            Thread.delay 0.05;
            wait (remaining -. 0.05))
        in
        wait seconds;
        if not !disarmed then try Unix.kill pid Sys.sigkill with _ -> ())
      ()
  in
  fun () ->
    disarmed := true;
    Thread.join thread

let live_transition =
  {|{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":0}}]}|}

(* Two connections in sequence. The first delivers a value and then breaks the
   protocol; the second replays the query set and repeats the identical value.
   That repeat is the interesting part: the client suppresses an unchanged
   rehydration, so it must treat the error it already published as the
   subscriber's current state or the subscription stays stranded. *)
let start_recovering_live_fixture () =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 2;
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let thread =
    Thread.create
      (fun () ->
        Fun.protect
          ~finally:(fun () -> Unix.close listener)
          (fun () ->
            let serve break_protocol =
              let socket, _ = Unix.accept listener in
              let input = Unix.in_channel_of_descr socket in
              let output = Unix.out_channel_of_descr socket in
              Fun.protect
                ~finally:(fun () ->
                  close_in_noerr input;
                  close_out_noerr output)
                (fun () ->
                  let rec headers () =
                    if input_line input <> "\r" then headers ()
                  in
                  headers ();
                  output_string output
                    "HTTP/1.1 101 Switching Protocols\r\n\
                     Upgrade: websocket\r\n\
                     Connection: Upgrade\r\n\
                     \r\n";
                  flush output;
                  (* Connect, then ModifyQuerySet carrying the Add. *)
                  ignore (read_websocket_frame input);
                  ignore (read_websocket_frame input);
                  write_websocket_text output live_transition;
                  if break_protocol then
                    write_websocket_text output "{ this is not JSON"
                  else Thread.delay 1.5)
            in
            serve true;
            serve false))
      ()
  in
  (port, thread)

let test_serialized_subscription_recovery executable =
  let port, fixture = start_recovering_live_fixture () in
  let process =
    start_adapter executable (Printf.sprintf "http://127.0.0.1:%d" port)
  in
  let disarm = watchdog 30.0 process.pid in
  send process
    {|{"id":"subscribe-repair","op":"subscribe","subscriptionId":"room-repair","path":"tests:live","args":{}}|};
  let ack = receive process in
  require_string "type" "ack" ack;
  require_string "id" "subscribe-repair" ack;
  let initial = receive process in
  require_string "type" "subscription" initial;
  require_string "subscriptionId" "room-repair" initial;
  require
    (member "value" initial = Some (`Assoc [ ("count", `Int 0) ]))
    ("initial live value was " ^ J.to_string initial);
  let failure = receive process in
  require_string "type" "subscription" failure;
  require_string "subscriptionId" "room-repair" failure;
  (match member "error" failure with
  | Some body -> require_string "name" "ProtocolError" body
  | None -> fail ("protocol error event was " ^ J.to_string failure));
  let repaired = receive process in
  require_string "type" "subscription" repaired;
  require_string "subscriptionId" "room-repair" repaired;
  require
    (member "error" repaired = None)
    ("recovered event still carried an error: " ^ J.to_string repaired);
  require
    (member "value" repaired = Some (`Assoc [ ("count", `Int 0) ]))
    ("recovered live value was " ^ J.to_string repaired);
  send process {|{"id":"close-repair","op":"close"}|};
  let closed = receive process in
  require_string "type" "closed" closed;
  require_string "id" "close-repair" closed;
  finish process;
  disarm ();
  Thread.join fixture

let () =
  if Array.length Sys.argv <> 2 then fail "adapter_tests requires main.exe";
  test_serialized_http_and_validation Sys.argv.(1);
  test_serialized_subscription_error Sys.argv.(1);
  test_serialized_subscription_recovery Sys.argv.(1);
  print_endline "PASS OCaml serialized adapter fixtures"
