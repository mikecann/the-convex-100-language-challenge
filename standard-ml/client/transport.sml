(* Deadline-bounded byte transport: plain TCP, and TLS driven through OpenSSL
   memory BIOs.

   Using memory BIOs rather than handing OpenSSL a file descriptor is what keeps
   every deadline in this client honest. OpenSSL only ever transforms buffers;
   Standard ML decides when to wait, for how long, and when to give up. It also
   means no foreign call ever blocks, which matters because a blocked foreign
   call would stall Poly/ML's garbage collector for every other thread. *)

structure Transport =
struct
  (* Raised when a deadline passes. Callers distinguish this from end of stream
     because a timeout part-way through a WebSocket frame must abandon the
     connection rather than resume at a false frame boundary. *)
  exception Timeout

  type sock = Socket.active INetSock.stream_sock

  val chunkSize = 16384

  (* Never sit inside one select for long: the Live owner has to stay responsive
     to queued commands even while it is waiting for the server. *)
  val pollSlice = 0.05

  (* The two memory buffers are kept beside the session rather than queried back
     out of OpenSSL, so the pump code below never has to ask which buffer is
     which. *)
  datatype security =
      Plain
    | Secure of {ctx: Ssl.ptr, ssl: Ssl.ptr, rbio: Ssl.ptr, wbio: Ssl.ptr}

  type t =
    {socket: sock,
     security: security,
     closed: bool ref}

  fun transportFail message = ConvexError.fail ("TransportError", message)

  (* ---- raw socket helpers ------------------------------------------ *)

  fun waitReadable (socket, deadline) =
    let
      fun loop () =
        if Clock.expired deadline then raise Timeout
        else
          let
            val slice = Real.min (pollSlice, Clock.remainingSeconds deadline)
            val {rds, ...} =
              Socket.select
                {rds = [Socket.sockDesc socket], wrs = [], exs = [],
                 timeout = SOME (Time.fromReal slice)}
          in
            if List.null rds then loop () else ()
          end
    in
      loop ()
    end

  fun waitWritable (socket, deadline) =
    let
      fun loop () =
        if Clock.expired deadline then raise Timeout
        else
          let
            val slice = Real.min (pollSlice, Clock.remainingSeconds deadline)
            val {wrs, ...} =
              Socket.select
                {rds = [], wrs = [Socket.sockDesc socket], exs = [],
                 timeout = SOME (Time.fromReal slice)}
          in
            if List.null wrs then loop () else ()
          end
    in
      loop ()
    end

  (* Returns "" at end of stream and raises Timeout at the deadline. *)
  fun rawRead (socket, limit, deadline) =
    let
      fun loop () =
        case Socket.recvVecNB (socket, Int.min (limit, chunkSize)) of
            SOME data =>
              if Word8Vector.length data = 0 then "" else Bytes.toString data
          | NONE => (waitReadable (socket, deadline); loop ())
    in
      loop ()
    end

  fun rawWriteAll (socket, text, deadline) =
    let
      val bytes = Bytes.fromString text
      val total = Word8Vector.length bytes
      fun loop offset =
        if offset >= total then ()
        else
          case Socket.sendVecNB
                 (socket, Word8VectorSlice.slice (bytes, offset, SOME (total - offset))) of
              SOME written =>
                if written <= 0 then transportFail "socket accepted no bytes"
                else loop (offset + written)
            | NONE => (waitWritable (socket, deadline); loop offset)
    in
      loop 0
    end

  (* ---- TLS over memory BIOs ---------------------------------------- *)

  fun bioPending bio =
    let
      val {bioCtrl, ...} = Ssl.api ()
    in
      bioCtrl (bio, Ssl.CTRL_PENDING, 0, Ssl.null)
    end

  (* Drain everything OpenSSL wants to send and put it on the wire. *)
  fun flushOutgoing (socket, wbio, deadline) =
    let
      val {bioRead, ...} = Ssl.api ()
      fun loop () =
        let
          val pending = bioPending wbio
        in
          if pending <= 0 then ()
          else
            let
              val want = Int.min (pending, chunkSize)
              val text =
                Ssl.withBuffer
                  (want,
                   fn buffer =>
                     let
                       val got = bioRead (wbio, buffer, want)
                     in
                       if got <= 0 then "" else Ssl.getBytes (buffer, got)
                     end)
            in
              if text = "" then ()
              else (rawWriteAll (socket, text, deadline); loop ())
            end
        end
    in
      loop ()
    end

  (* Read one chunk of ciphertext from the wire and give it to OpenSSL.
     Returns false at end of stream. *)
  fun feedIncoming (socket, rbio, deadline) =
    let
      val {bioWrite, ...} = Ssl.api ()
      val text = rawRead (socket, chunkSize, deadline)
    in
      if text = "" then false
      else
        (Ssl.withBuffer
           (String.size text,
            fn buffer =>
              (Ssl.putBytes (buffer, text);
               if bioWrite (rbio, buffer, String.size text) <> String.size text then
                 transportFail "OpenSSL rejected inbound ciphertext"
               else ()));
         true)
    end

  fun looksLikeIpv4 host =
    let
      val parts = String.tokens (fn character => character = #".") host
      fun octet text =
        String.size text > 0 andalso String.size text <= 3
        andalso CharVector.all Char.isDigit text
        andalso (case Int.fromString text of SOME value => value <= 255 | NONE => false)
    in
      List.length parts = 4 andalso List.all octet parts
    end

  fun startTls (socket, host, deadline) =
    let
      val api = Ssl.api ()
      val {ctxNew, ctxSetDefaultVerifyPaths, ctxSetVerify, sslNew, sslSetBio,
           sslSetConnectState, sslCtrl, sslSet1Host, sslGet0Param, paramSet1IpAsc,
           sslDoHandshake, sslGetError, sslGetVerifyResult, bioNewMem, bioCtrl,
           ctxFree, sslFree, ...} = api
      val ctx = ctxNew ()
      val _ = if Ssl.isNull ctx then transportFail "could not create a TLS context" else ()
      fun abandon message =
        (ctxFree ctx; transportFail message)
      val _ =
        if ctxSetDefaultVerifyPaths ctx <> 1 then
          abandon "could not load the trusted certificate roots"
        else ()
      val _ = ctxSetVerify (ctx, Ssl.VERIFY_PEER, Ssl.null)
      val ssl = sslNew ctx
      val _ = if Ssl.isNull ssl then abandon "could not create a TLS session" else ()
      val rbio = bioNewMem ()
      val wbio = bioNewMem ()
      val _ =
        if Ssl.isNull rbio orelse Ssl.isNull wbio then
          (sslFree ssl; abandon "could not create TLS memory buffers")
        else ()
      (* Report "retry later" instead of end of stream when a memory buffer is
         empty, so an empty read means "pump more bytes", not "connection over". *)
      val _ = bioCtrl (rbio, Ssl.C_SET_BUF_MEM_EOF_RETURN, ~1, Ssl.null)
      val _ = bioCtrl (wbio, Ssl.C_SET_BUF_MEM_EOF_RETURN, ~1, Ssl.null)
      (* SSL_set_bio hands both buffers to the session, which frees them. *)
      val _ = sslSetBio (ssl, rbio, wbio)
      val _ = sslSetConnectState ssl
      (* Verify the name the caller actually asked for. A certificate that is
         merely well formed and trusted is not enough. *)
      val _ =
        if looksLikeIpv4 host then
          (if paramSet1IpAsc (sslGet0Param ssl, host) <> 1 then
             (sslFree ssl; abandon "could not pin the requested IP address")
           else ())
        else
          (if sslSet1Host (ssl, host) <> 1 then
             (sslFree ssl; abandon "could not pin the requested host name")
           else
             (* SNI is meaningless for an IP literal, so it is only sent here. *)
             ignore (sslCtrl (ssl, Ssl.CTRL_SET_TLSEXT_HOSTNAME,
                              Ssl.TLSEXT_NAMETYPE_host_name, host)))
      fun handshake () =
        let
          val result = sslDoHandshake ssl
        in
          if result = 1 then ()
          else
            let
              val reason = sslGetError (ssl, result)
            in
              if reason = Ssl.ERROR_WANT_READ then
                (flushOutgoing (socket, wbio, deadline);
                 if feedIncoming (socket, rbio, deadline) then handshake ()
                 else transportFail "TLS peer closed during the handshake")
              else if reason = Ssl.ERROR_WANT_WRITE then
                (flushOutgoing (socket, wbio, deadline); handshake ())
              else
                transportFail
                  ("TLS handshake failed: " ^ Ssl.lastErrorText ())
            end
        end
      val _ =
        handshake ()
        handle exn => (sslFree ssl; ctxFree ctx; raise exn)
      val _ = flushOutgoing (socket, wbio, deadline)
      val verified = sslGetVerifyResult ssl
      val _ =
        if verified <> 0 then
          (sslFree ssl;
           ctxFree ctx;
           transportFail ("TLS certificate was rejected with code " ^ Int.toString verified))
        else ()
    in
      Secure {ctx = ctx, ssl = ssl, rbio = rbio, wbio = wbio}
    end

  (* ---- public transport -------------------------------------------- *)

  fun resolve host =
    case NetHostDB.getByName host of
        SOME entry => NetHostDB.addr entry
      | NONE => transportFail ("could not resolve host " ^ host)

  fun connect {host, port, secure, deadline} : t =
    let
      val address = INetSock.toAddr (resolve host, port)
      val socket = INetSock.TCP.socket ()
      val _ =
        (if Socket.connectNB (socket, address) then ()
         else waitWritable (socket, deadline))
        handle Timeout => (Socket.close socket; transportFail "TCP connect timed out")
             | exn => (Socket.close socket; raise exn)
      val _ =
        if Socket.Ctl.getERROR socket then
          (Socket.close socket; transportFail ("could not connect to " ^ host))
        else ()
      val security =
        if secure then
          startTls (socket, host, deadline)
          handle Timeout => (Socket.close socket; transportFail "TLS handshake timed out")
               | exn => (Socket.close socket; raise exn)
        else Plain
    in
      {socket = socket, security = security, closed = ref false}
    end

  (* Wrap an already-accepted socket. The deterministic test fixtures serve
     plain HTTP and raw WebSocket bytes through the same reader as the client. *)
  fun ofSocket socket : t =
    {socket = socket, security = Plain, closed = ref false}

  (* Returns "" at end of stream. Raises Transport.Timeout at the deadline, so
     a reader can tell a quiet stream from a finished one. *)
  fun readSome ({socket, security, closed} : t, limit, deadline) =
    if !closed then transportFail "transport is closed"
    else
      case security of
          Plain => rawRead (socket, limit, deadline)
        | Secure {ssl, rbio, wbio, ...} =>
            let
              val {sslRead, sslGetError, ...} = Ssl.api ()
              val want = Int.min (limit, chunkSize)
              fun attempt () =
                let
                  val (got, text) =
                    Ssl.withBuffer
                      (want,
                       fn buffer =>
                         let
                           val got = sslRead (ssl, buffer, want)
                         in
                           (got, if got > 0 then Ssl.getBytes (buffer, got) else "")
                         end)
                in
                  if got > 0 then text
                  else
                    let
                      val reason = sslGetError (ssl, got)
                    in
                      if reason = Ssl.ERROR_ZERO_RETURN then ""
                      else if reason = Ssl.ERROR_WANT_READ then
                        (flushOutgoing (socket, wbio, deadline);
                         if feedIncoming (socket, rbio, deadline) then attempt () else "")
                      else if reason = Ssl.ERROR_WANT_WRITE then
                        (flushOutgoing (socket, wbio, deadline); attempt ())
                      else transportFail ("TLS read failed: " ^ Ssl.lastErrorText ())
                    end
                end
            in
              attempt ()
            end

  (* Writes never leak the raw Timeout exception: only a reader needs to tell a
     quiet stream from a late one. *)
  fun writeAll (channel : t, text, deadline) =
    writeAllRaw (channel, text, deadline)
    handle Timeout => transportFail "transport write passed its deadline"

  and writeAllRaw ({socket, security, closed, ...} : t, text, deadline) =
    if !closed then transportFail "transport is closed"
    else
      case security of
          Plain => rawWriteAll (socket, text, deadline)
        | Secure {ssl, rbio, wbio, ...} =>
            let
              val {sslWrite, sslGetError, ...} = Ssl.api ()
              val total = String.size text
              fun attempt offset =
                if offset >= total then flushOutgoing (socket, wbio, deadline)
                else
                  let
                    val want = Int.min (total - offset, chunkSize)
                    val slice = String.substring (text, offset, want)
                    val written =
                      Ssl.withBuffer
                        (want,
                         fn buffer =>
                           (Ssl.putBytes (buffer, slice); sslWrite (ssl, buffer, want)))
                  in
                    if written > 0 then
                      (flushOutgoing (socket, wbio, deadline);
                       attempt (offset + written))
                    else
                      let
                        val reason = sslGetError (ssl, written)
                      in
                        if reason = Ssl.ERROR_WANT_READ then
                          (flushOutgoing (socket, wbio, deadline);
                           if feedIncoming (socket, rbio, deadline) then attempt offset
                           else transportFail "TLS peer closed during a write")
                        else if reason = Ssl.ERROR_WANT_WRITE then
                          (flushOutgoing (socket, wbio, deadline); attempt offset)
                        else transportFail ("TLS write failed: " ^ Ssl.lastErrorText ())
                      end
                  end
            in
              attempt 0
            end

  fun close ({socket, security, closed, ...} : t) =
    if !closed then ()
    else
      (closed := true;
       (case security of
            Plain => ()
          | Secure {ctx, ssl, wbio, ...} =>
              let
                val {sslShutdown, sslFree, ctxFree, ...} = Ssl.api ()
              in
                (* Best effort only. A peer that has already gone away must not
                   be able to hold the caller past its deadline. *)
                (ignore (sslShutdown ssl)
                 handle _ => ());
                (flushOutgoing (socket, wbio, Clock.deadlineIn 0.25)
                 handle _ => ());
                (sslFree ssl handle _ => ());
                (ctxFree ctx handle _ => ())
              end);
       (Socket.close socket handle _ => ()))
end

(* A byte reader with a small pushback buffer.
   Both the HTTP response parser and the RFC 6455 frame parser need to know
   whether any byte of the current message has already been consumed, so the
   buffer state lives here rather than inside either parser. *)
structure Reader =
struct
  type t = {transport: Transport.t, buffer: string ref, offset: int ref}

  val maxLine = 8192

  fun new transport : t = {transport = transport, buffer = ref "", offset = ref 0}

  fun buffered ({buffer, offset, ...} : t) = String.size (!buffer) - !offset

  (* Returns false at end of stream. Raises Transport.Timeout at the deadline. *)
  fun fill ({transport, buffer, offset} : t, deadline) =
    let
      val text = Transport.readSome (transport, Transport.chunkSize, deadline)
    in
      if text = "" then false
      else (buffer := text; offset := 0; true)
    end

  fun byte (reader as {buffer, offset, ...} : t, deadline) =
    if buffered reader > 0 then
      let
        val character = String.sub (!buffer, !offset)
      in
        offset := !offset + 1;
        SOME character
      end
    else if fill (reader, deadline) then byte (reader, deadline)
    else NONE

  (* A short read is never silently accepted: a TCP segment boundary must not
     move the frame parser to a byte that is not a frame header. *)
  fun exact (reader as {buffer, offset, ...} : t, count, deadline) =
    let
      val output = Buffer.new ()
      fun loop remaining =
        if remaining <= 0 then Buffer.contents output
        else
          let
            val have = buffered reader
          in
            if have > 0 then
              let
                val take = Int.min (have, remaining)
              in
                Buffer.add (output, String.substring (!buffer, !offset, take));
                offset := !offset + take;
                loop (remaining - take)
              end
            else if fill (reader, deadline) then loop remaining
            else ConvexError.fail ("TransportError", "stream ended mid-message")
          end
    in
      loop count
    end

  (* Reads one CRLF- or LF-terminated line. NONE means a clean end of stream
     before any byte of a new line arrived. *)
  fun line (reader, deadline) =
    let
      val output = Buffer.new ()
      fun loop () =
        if Buffer.size output > maxLine then
          ConvexError.fail ("ProtocolError", "header line exceeds 8192 bytes")
        else
          case byte (reader, deadline) of
              NONE => if Buffer.size output = 0 then NONE else SOME (Buffer.contents output)
            | SOME #"\n" =>
                let
                  val text = Buffer.contents output
                  val size = String.size text
                in
                  SOME
                    (if size > 0 andalso String.sub (text, size - 1) = #"\r" then
                       String.substring (text, 0, size - 1)
                     else text)
                end
            | SOME character => (Buffer.addChar (output, character); loop ())
    in
      loop ()
    end
end
