(* Convex's documented JSON HTTP endpoints, spoken directly over the transport.
   The request is small enough to write by hand, which keeps the demonstration
   free of a delegated HTTP client and makes every header on the wire visible in
   one place. *)

structure Url =
struct
  type t = {secure: bool, host: string, port: int}

  fun reject message = ConvexError.fail ("ProtocolError", message)

  fun parsePort text =
    case Int.fromString text of
        SOME value =>
          if value >= 1 andalso value <= 65535 then value
          else reject "deployment URL has an out-of-range port"
      | NONE => reject "deployment URL has a malformed port"

  (* Accept only an absolute origin. A query, fragment, or embedded credential
     would silently change which deployment the client talks to. *)
  fun parse text =
    let
      val _ =
        if Text.headerSafe text then () else reject "deployment URL contains a newline"
      val _ =
        if Text.contains (text, #"?") orelse Text.contains (text, #"#") then
          reject "deployment URL must not carry a query or fragment"
        else ()
      val secure = Text.startsWith ("https://", text)
      val _ =
        if secure orelse Text.startsWith ("http://", text) then ()
        else reject "deployment URL must be an absolute HTTP or HTTPS URL"
      val schemeEnd = if secure then 8 else 7
      val authorityEnd =
        case Text.indexFrom (text, #"/", schemeEnd) of
            SOME index => index
          | NONE => String.size text
      val authority = String.substring (text, schemeEnd, authorityEnd - schemeEnd)
      val _ =
        if Text.contains (authority, #"@") then
          reject "deployment URL must not contain credentials"
        else ()
      (* Bracketed IPv6 authorities are rejected rather than half-supported;
         the transport resolves IPv4 addresses only. *)
      val _ =
        if Text.contains (authority, #"[") then
          reject "IPv6 deployment URLs are not supported"
        else ()
      val (host, port) =
        case Text.lastIndex (authority, #":") of
            SOME index =>
              (String.substring (authority, 0, index),
               parsePort (String.extract (authority, index + 1, NONE)))
          | NONE => (authority, if secure then 443 else 80)
      val _ = if host = "" then reject "deployment URL has an empty host" else ()
    in
      {secure = secure, host = host, port = port}
    end

  (* The Host header repeats the authority exactly as the caller wrote it, so a
     non-default port still reaches the right virtual host. *)
  fun hostHeader ({secure, host, port, ...} : t) =
    if (secure andalso port = 443) orelse ((not secure) andalso port = 80) then host
    else host ^ ":" ^ Int.toString port
end

structure Http =
struct
  type response = {status: int, body: string}

  val maxBody = Json.maxBytes

  fun buildRequest {url, path, body, token, version} =
    let
      val authorization =
        if token = "" then "" else "Authorization: Bearer " ^ token ^ "\r\n"
    in
      String.concat
        ["POST ", path, " HTTP/1.1\r\n",
         "Host: ", Url.hostHeader url, "\r\n",
         "Content-Type: application/json\r\n",
         "Accept: application/json\r\n",
         (* One request per connection keeps response framing to the single
            documented case; persistent connections are deferred. *)
         "Connection: close\r\n",
         "Convex-Client: ", version, "\r\n",
         "Content-Length: ", Int.toString (String.size body), "\r\n",
         authorization,
         "\r\n",
         body]
    end

  fun parseStatus line =
    if String.size line >= 12 andalso Text.startsWith ("HTTP/", line) then
      case Int.fromString (String.substring (line, 9, 3)) of
          SOME status => status
        | NONE => ConvexError.fail ("ProtocolError", "HTTP status line is malformed")
    else ConvexError.fail ("ProtocolError", "HTTP status line is malformed")

  fun readHeaders (reader, deadline) =
    let
      fun loop (headers, count) =
        if count > 64 then
          ConvexError.fail ("ProtocolError", "HTTP response has too many headers")
        else
          case Reader.line (reader, deadline) of
              NONE => ConvexError.fail ("ProtocolError", "HTTP headers ended unexpectedly")
            | SOME "" => List.rev headers
            | SOME line =>
                (case Text.indexFrom (line, #":", 0) of
                     NONE => ConvexError.fail ("ProtocolError", "HTTP header is malformed")
                   | SOME index =>
                       loop
                         ((Text.lower (String.substring (line, 0, index)),
                           Text.trim (String.extract (line, index + 1, NONE)))
                          :: headers,
                          count + 1))
    in
      loop ([], 0)
    end

  fun header (headers, name) =
    Option.map #2 (List.find (fn (key, _) => key = name) headers)

  fun readBody (reader, headers, deadline) =
    let
      val _ =
        case header (headers, "transfer-encoding") of
            SOME encoding =>
              if Text.lower encoding = "identity" then ()
              else
                ConvexError.fail
                  ("ProtocolError", "chunked HTTP response framing is not supported")
          | NONE => ()
      val output = Buffer.new ()
      fun drain () =
        if Buffer.size output > maxBody then
          ConvexError.fail ("TransportError", "HTTP response exceeds 2097152 bytes")
        else
          case Reader.byte (reader, deadline) of
              NONE => Buffer.contents output
            | SOME character => (Buffer.addChar (output, character); drain ())
    in
      case Option.mapPartial Int.fromString (header (headers, "content-length")) of
          SOME length =>
            if length < 0 orelse length > maxBody then
              ConvexError.fail ("TransportError", "HTTP response exceeds 2097152 bytes")
            else Reader.exact (reader, length, deadline)
        | NONE => drain ()
    end

  (* One call, one connection, one bounded response. Connecting has its own,
     shorter budget so a peer that accepts TCP and then stalls cannot consume
     the whole request deadline before the request is even sent. *)
  fun call {url : Url.t, path, body, token, version, connectDeadline, deadline} : response =
    let
      val transport =
        Transport.connect
          {host = #host url, port = #port url, secure = #secure url,
           deadline = connectDeadline}
      (* The connection is closed on every path, including a deadline that
         expires while the response is still arriving. *)
      val result =
        (let
           val _ =
             Transport.writeAll
               (transport, buildRequest {url = url, path = path, body = body,
                                         token = token, version = version}, deadline)
           val reader = Reader.new transport
           val status =
             case Reader.line (reader, deadline) of
                 SOME line => parseStatus line
               | NONE => ConvexError.fail ("TransportError", "HTTP response was empty")
           val headers = readHeaders (reader, deadline)
         in
           {status = status, body = readBody (reader, headers, deadline)}
         end)
        handle Transport.Timeout =>
                 (Transport.close transport;
                  ConvexError.fail ("TransportError", "HTTP request timed out"))
             | exn => (Transport.close transport; raise exn)
    in
      Transport.close transport;
      result
    end
end
