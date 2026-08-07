(* RFC 6455 framing in Standard ML.
   Convex Live is a WebSocket protocol, so the frame layer is part of the
   client rather than something delegated to another runtime. The format is
   small enough to read end to end, which is the point of the demonstration. *)

structure WebSocket =
struct
  datatype opcode =
      Continuation
    | TextFrame
    | BinaryFrame
    | CloseFrame
    | Ping
    | Pong
    | Reserved of int

  type frame = {fin: bool, opcode: opcode, payload: string}

  type t = {transport: Transport.t, reader: Reader.t}

  (* A single Live message is capped well below the shared 128 MiB runtime
     limit so a hostile length header cannot force an allocation. *)
  val maxMessage = 2 * 1024 * 1024

  val guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  fun protocolFail message = ConvexError.fail ("ProtocolError", message)

  fun transportFail message = ConvexError.fail ("TransportError", message)

  fun opcodeOf value =
    case value of
        0 => Continuation
      | 1 => TextFrame
      | 2 => BinaryFrame
      | 8 => CloseFrame
      | 9 => Ping
      | 10 => Pong
      | other => Reserved other

  fun opcodeValue opcode =
    case opcode of
        Continuation => 0
      | TextFrame => 1
      | BinaryFrame => 2
      | CloseFrame => 8
      | Ping => 9
      | Pong => 10
      | Reserved value => value

  fun isControl opcode =
    case opcode of
        CloseFrame => true
      | Ping => true
      | Pong => true
      | _ => false

  (* ---- handshake ---------------------------------------------------- *)

  fun acceptFor key = Base64.encode (Sha1.hash (key ^ guid))

  fun readHandshake (reader, expected, deadline) =
    let
      val status =
        case Reader.line (reader, deadline) of
            SOME line => line
          | NONE => transportFail "WebSocket upgrade produced no response"
      val _ =
        if Text.startsWith ("HTTP/1.1 101 ", status) then ()
        else protocolFail "WebSocket upgrade was rejected"
      fun loop (accept, count) =
        if count > 64 then protocolFail "WebSocket handshake has too many headers"
        else
          case Reader.line (reader, deadline) of
              NONE => transportFail "WebSocket handshake ended unexpectedly"
            | SOME "" =>
                (case accept of
                     SOME value =>
                       if value = expected then ()
                       else protocolFail "WebSocket accept key did not match"
                   | NONE => protocolFail "WebSocket handshake omitted the accept key")
            | SOME line =>
                (case Text.indexFrom (line, #":", 0) of
                     NONE => protocolFail "WebSocket handshake header is malformed"
                   | SOME index =>
                       let
                         val name = Text.lower (String.substring (line, 0, index))
                         val value = Text.trim (String.extract (line, index + 1, NONE))
                       in
                         loop
                           (if name = "sec-websocket-accept" then SOME value else accept,
                            count + 1)
                       end)
    in
      loop (NONE, 0)
    end

  fun connect {url : Url.t, path, version, deadline} : t =
    let
      val transport =
        Transport.connect
          {host = #host url, port = #port url, secure = #secure url, deadline = deadline}
      val key = Base64.encode (Rand.bytes 16)
      val request =
        String.concat
          ["GET ", path, " HTTP/1.1\r\n",
           "Host: ", Url.hostHeader url, "\r\n",
           "Upgrade: websocket\r\n",
           "Connection: Upgrade\r\n",
           "Sec-WebSocket-Key: ", key, "\r\n",
           "Sec-WebSocket-Version: 13\r\n",
           "Convex-Client: ", version, "\r\n\r\n"]
      val reader = Reader.new transport
    in
      (Transport.writeAll (transport, request, deadline);
       readHandshake (reader, acceptFor key, deadline);
       {transport = transport, reader = reader})
      handle Transport.Timeout =>
               (Transport.close transport;
                transportFail "WebSocket handshake timed out")
           | exn => (Transport.close transport; raise exn)
    end

  (* ---- sending ------------------------------------------------------ *)

  (* Every client frame is masked, as RFC 6455 requires, with fresh kernel
     randomness rather than a counter. *)
  fun encode {fin, opcode, payload} =
    let
      val size = String.size payload
      val mask = Rand.bytes 4
      val first = Bytes.ofByte ((if fin then 128 else 0) + opcodeValue opcode)
      val length =
        if size < 126 then Bytes.ofByte (128 + size)
        else if size < 65536 then Bytes.ofByte (128 + 126) ^ Bytes.u16 size
        else Bytes.ofByte (128 + 127) ^ Bytes.u64 (IntInf.fromInt size)
    in
      String.concat [first, length, mask, Bytes.xorMask (payload, mask)]
    end

  fun send ({transport, ...} : t, frame, deadline) =
    Transport.writeAll (transport, encode frame, deadline)

  fun sendText (socket, text, deadline) =
    send (socket, {fin = true, opcode = TextFrame, payload = text}, deadline)

  fun sendPong (socket, payload, deadline) =
    send (socket, {fin = true, opcode = Pong, payload = payload}, deadline)

  (* 1000 is the normal closure status code. *)
  fun sendClose (socket, deadline) =
    send (socket,
          {fin = true, opcode = CloseFrame, payload = Bytes.ofByte 3 ^ Bytes.ofByte 232},
          deadline)

  (* ---- receiving ----------------------------------------------------- *)

  (* Returns NONE only when nothing at all arrived before idleDeadline. Once the
     first byte of a frame has been taken, frameDeadline applies and a timeout
     raises: the parser must never resume at a byte that is not a frame header. *)
  datatype start = Idle | Ended | Began of char

  fun receive ({reader, ...} : t, idleDeadline, frameDeadline) =
    let
      val start =
        (case Reader.byte (reader, idleDeadline) of
             SOME character => Began character
           | NONE => Ended)
        handle Transport.Timeout => Idle
    in
      case start of
          Idle => NONE
        | Ended => transportFail "WebSocket stream ended between frames"
        | Began first =>
            let
              fun next () =
                case Reader.byte (reader, frameDeadline) of
                    SOME character => Char.ord character
                  | NONE => transportFail "WebSocket stream ended mid-frame"
              val header = Char.ord first
              val fin = header >= 128
              val reserved = (header div 16) mod 8
              val opcode = opcodeOf (header mod 16)
              val second = next ()
              val masked = second >= 128
              val marker = second mod 128
              val length =
                if marker < 126 then IntInf.fromInt marker
                else if marker = 126 then
                  IntInf.fromInt (Bytes.readU16 (Reader.exact (reader, 2, frameDeadline), 0))
                else Bytes.readU64 (Reader.exact (reader, 8, frameDeadline), 0)
              val _ =
                if reserved <> 0 then protocolFail "WebSocket frame set a reserved bit" else ()
              val _ = if masked then protocolFail "server WebSocket frame was masked" else ()
              val _ =
                if isControl opcode andalso (not fin orelse length > 125) then
                  protocolFail "invalid WebSocket control frame"
                else ()
              (* Reject a non-minimal length as well as an oversized one: both
                 are signs the peer is not speaking RFC 6455. *)
              val _ =
                if (marker = 126 andalso length < 126)
                   orelse (marker = 127 andalso length < 65536)
                   orelse length > IntInf.fromInt maxMessage then
                  protocolFail "invalid or oversized WebSocket frame"
                else ()
              val payload =
                Reader.exact (reader, IntInf.toInt length, frameDeadline)
            in
              SOME {fin = fin, opcode = opcode, payload = payload}
            end
            handle Transport.Timeout =>
                     transportFail "WebSocket frame stalled part-way through"
    end

  (* An empty payload is fine; a one-byte payload or an unassigned status code
     is not, and neither is a non-UTF-8 reason. *)
  fun closeFrameValid ({payload, ...} : frame) =
    let
      val size = String.size payload
    in
      if size = 0 then true
      else if size = 1 then false
      else
        let
          val code = Bytes.readU16 (payload, 0)
          val reason = String.extract (payload, 2, NONE)
        in
          (List.exists (fn allowed => allowed = code)
             [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011]
           orelse (code >= 3000 andalso code <= 4999))
          andalso Text.utf8Valid reason
        end
    end

  fun close ({transport, ...} : t) = Transport.close transport
end
