(* Deadline-bounded byte transport: plain TCP, and TLS driven through OpenSSL
   memory BIOs.

   Using memory BIOs rather than handing OpenSSL a file descriptor is what keeps
   every deadline in this client honest. OpenSSL only ever transforms buffers;
   Standard ML decides when to wait, for how long, and when to give up. It also
   means no foreign call ever blocks, which matters because a blocked foreign
   call would stall Poly/ML's garbage collector for every other thread. *)

structure Resolver =
struct
  (* Name resolution is the one operation the Basis Library cannot bound:
     NetHostDB.getByName blocks inside the C resolver until it answers, and no
     deadline reaches it. The Live owner opens sockets, so an unbounded lookup
     there would stall close and unsubscribe behind it.

     Three things keep that from happening. A literal address is converted
     directly and never reaches the resolver at all, which is the only case the
     deterministic fixtures use. A real name is looked up on its own thread, so
     the caller waits only until its own absolute deadline. The answer is then
     cached, so later connections to the same deployment never wait again.

     The cache is bounded in both directions. Entries expire, so a deployment
     that moves is followed rather than pinned for the life of the process, and
     a failure is remembered only briefly so a transient outage does not become
     a sticky one. The number of entries is bounded too, so a client pointed at
     many names cannot grow this table without limit. Every name keeps all the
     addresses the resolver returned, in order, so a connection can fail over to
     the next one and a reconnect can prefer the one that last worked. *)
  type address = NetHostDB.in_addr

  (* A resolved name is trusted for this long, and a failure for much less. *)
  val positiveTtlSeconds = 60.0
  val negativeTtlSeconds = 5.0

  (* More than any deployment this demonstration talks to, and small enough that
     the linear scans below stay trivial. *)
  val maxEntries = 64

  (* Enough for a round-robin record; the rest are dropped rather than retained.
     A name that answers with hundreds of addresses is not a Convex
     deployment. *)
  val maxAddresses = 8

  type entry = {addresses: address list, expires: Time.time}

  (* gethostbyname is not reentrant, so only one lookup thread runs at a time. *)
  val lookupMutex = Thread.Mutex.mutex ()
  val stateMutex = Thread.Mutex.mutex ()
  (* Newest first, so eviction can drop the tail. *)
  val cache : (string * entry) list ref = ref []
  val pending : (string * Latch.t) list ref = ref []

  fun resolverFail message = ConvexError.fail ("TransportError", message)

  (* NetHostDB.in_addr carries no equality, so addresses are compared by their
     printed form. *)
  fun sameAddress (left, right) = NetHostDB.toString left = NetHostDB.toString right

  (* Only a dotted-quad is treated as a literal. Anything else is a name, even
     when the platform's own converter would accept it. *)
  fun isLiteral host =
    let
      val parts = String.tokens (fn character => character = #".") host
      fun octet text =
        String.size text > 0 andalso String.size text <= 3
        andalso CharVector.all Char.isDigit text
        andalso (case Int.fromString text of SOME value => value <= 255 | NONE => false)
    in
      List.length parts = 4 andalso List.all octet parts
    end

  (* ---- pure cache rules ---------------------------------------------- *)

  (* Separated from the shared state so the eviction, expiry, negative, and
     rotation rules can be tested directly with explicit times rather than by
     waiting a minute for a real entry to age out. *)
  fun live ({expires, ...} : entry, now) = Time.< (now, expires)

  fun bound entries =
    if List.length entries <= maxEntries then entries else List.take (entries, maxEntries)

  fun clip addresses =
    if List.length addresses <= maxAddresses then addresses
    else List.take (addresses, maxAddresses)

  fun replace (entries, host, entry) =
    bound ((host, entry) :: List.filter (fn (name, _) => name <> host) entries)

  fun lookupIn (entries, host, now) =
    case List.find (fn (name, _) => name = host) entries of
        SOME (_, entry) => if live (entry, now) then SOME entry else NONE
      | NONE => NONE

  (* The address that just worked moves to the front, so the next connection to
     the same deployment starts where the last one succeeded instead of walking
     a dead address again. *)
  fun promoteIn (addresses, address) =
    address :: List.filter (fn item => not (sameAddress (item, address))) addresses

  (* ---- shared state --------------------------------------------------- *)

  fun cached host =
    Guard.critical (stateMutex, fn () => lookupIn (!cache, host, Clock.now ()))

  fun remember (host, addresses) =
    let
      val seconds = if List.null addresses then negativeTtlSeconds else positiveTtlSeconds
      val entry = {addresses = clip addresses, expires = Clock.deadlineIn seconds} : entry
    in
      Guard.critical (stateMutex, fn () => cache := replace (!cache, host, entry))
    end

  fun promote (host, address) =
    Guard.critical
      (stateMutex,
       fn () =>
         case List.find (fn (name, _) => name = host) (!cache) of
             SOME (_, {addresses, expires}) =>
               cache :=
                 replace (!cache, host,
                          {addresses = promoteIn (addresses, address), expires = expires})
           | NONE => ())

  (* Every cached address failed, so the entry is worse than useless: drop it and
     let the next attempt ask the resolver again. *)
  fun forget host =
    Guard.critical
      (stateMutex, fn () => cache := List.filter (fn (name, _) => name <> host) (!cache))

  (* Returns the latch to wait on and whether this caller owns the lookup, so a
     second caller for the same host joins the first attempt rather than
     starting a competing one. *)
  fun claim host =
    Guard.critical
      (stateMutex,
       fn () =>
         case List.find (fn (name, _) => name = host) (!pending) of
             SOME (_, latch) => (latch, false)
           | NONE =>
               let
                 val latch = Latch.new ()
               in
                 pending := (host, latch) :: !pending;
                 (latch, true)
               end)

  fun retire host =
    Guard.critical
      (stateMutex, fn () => pending := List.filter (fn (name, _) => name <> host) (!pending))

  (* A lookup that answers with nothing, or raises, is remembered as a negative
     entry. That is what stops a name that is down from starting a fresh
     resolver thread for every reconnect. *)
  fun lookup (host, latch) =
    ignore
      (Thread.Thread.fork
         (fn () =>
            ((Guard.critical
                (lookupMutex,
                 fn () =>
                   case NetHostDB.getByName host of
                       SOME found => remember (host, NetHostDB.addrs found)
                     | NONE => remember (host, []))
              handle _ => (remember (host, []) handle _ => ()));
             retire host;
             Latch.release latch),
          []))

  fun addresses (host, deadline) =
    if isLiteral host then
      (case NetHostDB.fromString host of
           SOME literal => [literal]
         | NONE => resolverFail ("could not read the address " ^ host))
    else
      let
        fun answer entry =
          if List.null (#addresses (entry : entry)) then
            resolverFail ("could not resolve host " ^ host)
          else #addresses entry
      in
        case cached host of
            SOME entry => answer entry
          | NONE =>
              let
                val (latch, owner) = claim host
                val _ = if owner then lookup (host, latch) else ()
                val answered = Latch.await (latch, deadline)
              in
                case cached host of
                    SOME entry => answer entry
                  | NONE =>
                      if answered then resolverFail ("could not resolve host " ^ host)
                      else resolverFail ("name resolution for " ^ host ^ " passed its deadline")
              end
      end

  fun address (host, deadline) =
    case addresses (host, deadline) of
        first :: _ => first
      | [] => resolverFail ("could not resolve host " ^ host)
end

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

  fun startTls (socket, host, deadline) =
    let
      val api = Ssl.api ()
      val {ctxNew, ctxSetDefaultVerifyPaths, ctxSetVerify, sslNew, sslSetBio,
           sslSetConnectState, sslCtrl, sslSet1Host, sslGet0Param, paramSet1IpAsc,
           sslDoHandshake, sslGetError, sslGetVerifyResult, bioNewMem, bioCtrl,
           bioFree, ctxFree, sslFree, ...} = api
      (* Every OpenSSL object this function creates is held in a slot, so one
         cleanup path frees exactly what exists however the attempt fails. A
         slot is emptied as it is freed, which is also how ownership is handed
         over: once SSL_set_bio has run, the session frees both buffers, so
         their slots are emptied without freeing them here. *)
      val ctxSlot = ref Ssl.null
      val sslSlot = ref Ssl.null
      val rbioSlot = ref Ssl.null
      val wbioSlot = ref Ssl.null
      fun discard (slot, free) =
        if Ssl.isNull (!slot) then ()
        else
          let
            val pointer = !slot
          in
            slot := Ssl.null;
            (free pointer handle _ => ())
          end
      fun releaseAll () =
        (discard (sslSlot, sslFree);
         discard (rbioSlot, bioFree);
         discard (wbioSlot, bioFree);
         discard (ctxSlot, ctxFree))
      fun abandon message = (releaseAll (); transportFail message)
      (* Anything that can raise after an object exists runs through here, so a
         deadline or a peer that disappears frees the session as reliably as a
         rejected certificate does. *)
      fun guarded body = body () handle exn => (releaseAll (); raise exn)
      val _ = ctxSlot := ctxNew ()
      val _ =
        if Ssl.isNull (!ctxSlot) then transportFail "could not create a TLS context" else ()
      val _ =
        if ctxSetDefaultVerifyPaths (!ctxSlot) <> 1 then
          abandon "could not load the trusted certificate roots"
        else ()
      val _ = ctxSetVerify (!ctxSlot, Ssl.VERIFY_PEER, Ssl.null)
      val _ = sslSlot := sslNew (!ctxSlot)
      val _ = if Ssl.isNull (!sslSlot) then abandon "could not create a TLS session" else ()
      val _ = rbioSlot := bioNewMem ()
      val _ = wbioSlot := bioNewMem ()
      val _ =
        if Ssl.isNull (!rbioSlot) orelse Ssl.isNull (!wbioSlot) then
          abandon "could not create TLS memory buffers"
        else ()
      val ssl = !sslSlot
      val rbio = !rbioSlot
      val wbio = !wbioSlot
      (* Report "retry later" instead of end of stream when a memory buffer is
         empty, so an empty read means "pump more bytes", not "connection over". *)
      val _ = bioCtrl (rbio, Ssl.C_SET_BUF_MEM_EOF_RETURN, ~1, Ssl.null)
      val _ = bioCtrl (wbio, Ssl.C_SET_BUF_MEM_EOF_RETURN, ~1, Ssl.null)
      (* SSL_set_bio hands both buffers to the session, which frees them. *)
      val _ = sslSetBio (ssl, rbio, wbio)
      val _ = (rbioSlot := Ssl.null; wbioSlot := Ssl.null)
      val _ = sslSetConnectState ssl
      (* Verify the name the caller actually asked for. A certificate that is
         merely well formed and trusted is not enough. *)
      val _ =
        guarded
          (fn () =>
             if Resolver.isLiteral host then
               (if paramSet1IpAsc (sslGet0Param ssl, host) <> 1 then
                  abandon "could not pin the requested IP address"
                else ())
             else
               (if sslSet1Host (ssl, host) <> 1 then
                  abandon "could not pin the requested host name"
                else
                  (* SNI is meaningless for an IP literal, so it is only sent
                     here. *)
                  ignore (sslCtrl (ssl, Ssl.CTRL_SET_TLSEXT_HOSTNAME,
                                   Ssl.TLSEXT_NAMETYPE_host_name, host))))
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
      val _ = guarded handshake
      val _ = guarded (fn () => flushOutgoing (socket, wbio, deadline))
      val verified = guarded (fn () => sslGetVerifyResult ssl)
      val _ =
        if verified <> 0 then
          abandon ("TLS certificate was rejected with code " ^ Int.toString verified)
        else ()
    in
      Secure {ctx = !ctxSlot, ssl = ssl, rbio = rbio, wbio = wbio}
    end

  (* ---- public transport -------------------------------------------- *)

  (* Listening sockets and the deterministic fixtures name a literal loopback
     address, which never reaches the resolver; the deadline is a backstop for
     anything else that ever calls this without one of its own. *)
  fun resolve host = Resolver.address (host, Clock.deadlineIn 5.0)

  (* One TCP attempt against one address, inside the caller's own deadline. *)
  fun connectTo (host, address, port, deadline) =
    let
      val socket = INetSock.TCP.socket ()
      val _ =
        (if Socket.connectNB (socket, INetSock.toAddr (address, port)) then ()
         else waitWritable (socket, deadline))
        handle Timeout => (Socket.close socket; transportFail "TCP connect timed out")
             | exn => (Socket.close socket; raise exn)
    in
      if Socket.Ctl.getERROR socket then
        (Socket.close socket; transportFail ("could not connect to " ^ host))
      else socket
    end

  fun connect {host, port, secure, deadline} : t =
    let
      (* Resolution shares the caller's connect deadline rather than sitting
         outside it. *)
      val candidates = Resolver.addresses (host, deadline)
      (* A name may answer with several addresses. Trying the next one after a
         refusal is what makes a rotated deployment reconnect instead of failing
         for as long as one stale address is first in the record. Failover stays
         inside the caller's single deadline: it never grants itself a fresh
         one, so a list of dead addresses cannot outlast the caller's budget. *)
      fun attempt (remaining, lastFailure) =
        case remaining of
            [] =>
              (Resolver.forget host;
               case lastFailure of
                   SOME failure => raise failure
                 | NONE => transportFail ("could not connect to " ^ host))
          | address :: rest =>
              (let
                 val socket = connectTo (host, address, port, deadline)
               in
                 Resolver.promote (host, address);
                 socket
               end)
              handle failure =>
                if List.null rest orelse Clock.expired deadline then
                  (Resolver.forget host; raise failure)
                else attempt (rest, SOME failure)
      val socket = attempt (candidates, NONE)
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
     plain HTTP and raw WebSocket bytes through the same reader as the client.

     Poly/ML puts every socket it opens itself into non-blocking mode, but a
     socket handed back by accept never goes through that step and Linux does
     not inherit the flag from the listener. That gap is not cosmetic here.
     Poly/ML's recvVecNB and sendVecNB are an ordinary recv and send inside the
     runtime, and they answer "would block" only when the descriptor itself
     says so: on an accepted socket they block in the runtime rather than
     returning NONE. A thread blocked inside the runtime never reaches a
     garbage-collection safe point, so the next collection stops every other
     thread - the Live owner among them - until the peer happens to send
     something. Setting the flag here is what keeps this file's promise that
     nothing blocks where only the Standard ML deadlines should decide. *)
  fun ofSocket socket : t =
    let
      val descriptor =
        case Posix.FileSys.iodToFD (Socket.ioDesc socket) of
            SOME value => value
          | NONE => transportFail "an accepted socket carried no file descriptor"
      val (flags, _) = Posix.IO.getfl descriptor
    in
      (Posix.IO.setfl (descriptor, Posix.IO.O.flags [flags, Posix.IO.O.nonblock])
       handle exn => ((Socket.close socket handle _ => ()); raise exn));
      {socket = socket, security = Plain, closed = ref false}
    end

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

  (* Hand back whatever is already buffered, in one piece. An unframed body is
     otherwise assembled one byte at a time, which is the shape that turns a
     large response into a large multiple of itself. Returns "" only at a clean
     end of stream, and raises Transport.Timeout at the deadline. *)
  fun chunk (reader as {buffer, offset, ...} : t, limit, deadline) =
    let
      val have = buffered reader
    in
      if have > 0 then
        let
          val take = Int.min (have, limit)
          val text = String.substring (!buffer, !offset, take)
        in
          offset := !offset + take;
          text
        end
      else if fill (reader, deadline) then chunk (reader, limit, deadline)
      else ""
    end

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
