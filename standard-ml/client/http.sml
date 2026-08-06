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

  fun malformedStatus () =
    ConvexError.fail ("ProtocolError", "HTTP status line is malformed")

  (* Only the two versions this client can speak, and only a real three-digit
     status. A lenient status line is the first step towards reading two
     responses as one, so every part of it is checked rather than scanned. *)
  fun parseStatus line =
    let
      val _ =
        if Text.startsWith ("HTTP/1.1 ", line) orelse Text.startsWith ("HTTP/1.0 ", line) then ()
        else malformedStatus ()
      val _ = if String.size line >= 12 then () else malformedStatus ()
      val digits = String.substring (line, 9, 3)
      val _ = if CharVector.all Char.isDigit digits then () else malformedStatus ()
      (* The reason phrase is optional, but when it is present a space has to
         separate it from the status code. *)
      val _ =
        if String.size line = 12 orelse String.sub (line, 12) = #" " then ()
        else malformedStatus ()
      val status = case Int.fromString digits of SOME value => value | NONE => malformedStatus ()
    in
      if status >= 100 andalso status <= 599 then status
      else ConvexError.fail ("ProtocolError", "HTTP status code is outside 100 to 599")
    end

  (* RFC 9110 token characters. A header name outside this set - or separated
     from its colon by a space - is how a smuggled second framing header gets
     past a lenient parser. *)
  fun tokenChar character =
    Char.isAlphaNum character
    orelse
      List.exists (fn allowed => allowed = character)
        [#"!", #"#", #"$", #"%", #"&", #"'", #"*", #"+", #"-", #".", #"^", #"_",
         #"`", #"|", #"~"]

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
                let
                  (* Obsolete line folding is rejected outright: a continuation
                     line can otherwise smuggle a value into the header above
                     it. *)
                  val _ =
                    if Char.isSpace (String.sub (line, 0)) then
                      ConvexError.fail ("ProtocolError", "HTTP response folds a header line")
                    else ()
                  val index =
                    case Text.indexFrom (line, #":", 0) of
                        SOME found => found
                      | NONE => ConvexError.fail ("ProtocolError", "HTTP header is malformed")
                  val name = String.substring (line, 0, index)
                  val _ =
                    if index > 0 andalso CharVector.all tokenChar name then ()
                    else ConvexError.fail ("ProtocolError", "HTTP header name is malformed")
                in
                  loop
                    ((Text.lower name, Text.trim (String.extract (line, index + 1, NONE)))
                     :: headers,
                     count + 1)
                end
    in
      loop ([], 0)
    end

  fun headerValues (headers : (string * string) list, name) =
    List.map #2 (List.filter (fn (key, _) => key = name) headers)

  (* A repeated framing header is rejected even when both copies agree: the
     client has no way to tell an origin server's duplicate from an
     intermediary's injected one. *)
  fun singleHeader (headers, name) =
    case headerValues (headers, name) of
        [] => NONE
      | [only] => SOME only
      | _ =>
          ConvexError.fail
            ("ProtocolError", "HTTP response repeats the " ^ name ^ " header")

  (* Digits and nothing else. Int.fromString would happily accept leading
     whitespace, a sign, or trailing rubbish, and each of those is a different
     length to a different parser. *)
  fun contentLength text =
    let
      val _ =
        if text <> "" andalso String.size text <= 18 andalso CharVector.all Char.isDigit text then
          ()
        else ConvexError.fail ("ProtocolError", "HTTP Content-Length is malformed")
    in
      case Int.fromString text of
          SOME value => value
        | NONE => ConvexError.fail ("ProtocolError", "HTTP Content-Length is malformed")
    end

  fun readBody (reader, headers, deadline) =
    let
      val encoding = singleHeader (headers, "transfer-encoding")
      val declared = singleHeader (headers, "content-length")
      (* Carrying both is the classic request-smuggling shape. Neither header
         wins here; the response is refused. *)
      val _ =
        case (encoding, declared) of
            (SOME _, SOME _) =>
              ConvexError.fail
                ("ProtocolError",
                 "HTTP response carries both Transfer-Encoding and Content-Length")
          | _ => ()
      (* This client asks for one request per connection, so no transfer coding
         is expected at all; chunked in particular is deferred rather than
         mis-parsed. *)
      val _ =
        case encoding of
            SOME value =>
              ConvexError.fail
                ("ProtocolError",
                 "unsupported HTTP transfer coding " ^ Text.lower (Text.trim value))
          | NONE => ()
      (* A connection-close response carries no declared length, so it is read
         in whole buffered chunks up to the same 2 MiB ceiling rather than one
         byte at a time. *)
      fun drain () =
        let
          val output = Buffer.new ()
          fun loop () =
            if Buffer.size output > maxBody then
              ConvexError.fail ("TransportError", "HTTP response exceeds 2097152 bytes")
            else
              case Reader.chunk (reader, Transport.chunkSize, deadline) of
                  "" => Buffer.contents output
                | text => (Buffer.add (output, text); loop ())
        in
          loop ()
        end
    in
      case declared of
          SOME text =>
            let
              val length = contentLength text
            in
              if length > maxBody then
                ConvexError.fail ("TransportError", "HTTP response exceeds 2097152 bytes")
              else Reader.exact (reader, length, deadline)
            end
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
