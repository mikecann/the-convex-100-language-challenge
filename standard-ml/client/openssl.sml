(* The complete OpenSSL surface this client uses, in one file.
   Standard ML has no TLS in its Basis Library, so TLS is the one facility
   borrowed from the platform. Everything Convex-specific still happens in
   Standard ML: this binding only encrypts and decrypts bytes.

   Two properties matter for the rest of the client:

   1. Every call here is short and non-blocking. TLS is driven through a pair of
      OpenSSL memory BIOs, so OpenSSL never touches a socket and never blocks
      Poly/ML's garbage collector inside a foreign call.
   2. Nothing is resolved at compile time. Poly/ML exports a heap image, so the
      library handles are built on first use at run time instead of being baked
      into the executable. *)

structure Ssl =
struct
  type ptr = Foreign.Memory.voidStar

  val null = Foreign.Memory.null

  (* SSL_get_error results the transport has to distinguish. *)
  val ERROR_WANT_READ = 2
  val ERROR_WANT_WRITE = 3
  val ERROR_ZERO_RETURN = 6

  val VERIFY_PEER = 1
  val CTRL_SET_TLSEXT_HOSTNAME = 55
  val TLSEXT_NAMETYPE_host_name = 0

  (* BIO_set_mem_eof_return is a macro over BIO_ctrl. Setting -1 makes an empty
     memory BIO report "retry later" instead of end of stream, which is what
     lets the transport pump bytes in from the socket. *)
  val C_SET_BUF_MEM_EOF_RETURN = 130
  val CTRL_PENDING = 10

  type api =
    {ctxNew: unit -> ptr,
     ctxFree: ptr -> unit,
     ctxSetDefaultVerifyPaths: ptr -> int,
     ctxSetVerify: ptr * int * ptr -> unit,
     sslNew: ptr -> ptr,
     sslFree: ptr -> unit,
     sslSetBio: ptr * ptr * ptr -> unit,
     sslSetConnectState: ptr -> unit,
     sslCtrl: ptr * int * int * string -> int,
     sslSet1Host: ptr * string -> int,
     sslGet0Param: ptr -> ptr,
     paramSet1IpAsc: ptr * string -> int,
     sslDoHandshake: ptr -> int,
     sslGetError: ptr * int -> int,
     sslRead: ptr * ptr * int -> int,
     sslWrite: ptr * ptr * int -> int,
     sslShutdown: ptr -> int,
     sslGetVerifyResult: ptr -> int,
     bioNewMem: unit -> ptr,
     bioWrite: ptr * ptr * int -> int,
     bioRead: ptr * ptr * int -> int,
     bioCtrl: ptr * int * int * ptr -> int,
     errGetError: unit -> int,
     errErrorString: int * ptr * int -> unit}

  val loaded : api option ref = ref NONE

  fun build () : api =
    let
      val ssl = Foreign.loadLibrary "libssl.so.3"
      val crypto = Foreign.loadLibrary "libcrypto.so.3"
      fun sslSymbol name = Foreign.getSymbol ssl name
      fun cryptoSymbol name = Foreign.getSymbol crypto name
      open Foreign
      val clientMethod = buildCall0 (sslSymbol "TLS_client_method", (), cPointer)
      val ctxNewRaw = buildCall1 (sslSymbol "SSL_CTX_new", cPointer, cPointer)
      val bioSMem = buildCall0 (cryptoSymbol "BIO_s_mem", (), cPointer)
      val bioNewRaw = buildCall1 (cryptoSymbol "BIO_new", cPointer, cPointer)
    in
      {ctxNew = fn () => ctxNewRaw (clientMethod ()),
       ctxFree = buildCall1 (sslSymbol "SSL_CTX_free", cPointer, cVoid),
       ctxSetDefaultVerifyPaths =
         buildCall1 (sslSymbol "SSL_CTX_set_default_verify_paths", cPointer, cInt),
       ctxSetVerify =
         buildCall3 (sslSymbol "SSL_CTX_set_verify", (cPointer, cInt, cPointer), cVoid),
       sslNew = buildCall1 (sslSymbol "SSL_new", cPointer, cPointer),
       sslFree = buildCall1 (sslSymbol "SSL_free", cPointer, cVoid),
       sslSetBio =
         buildCall3 (sslSymbol "SSL_set_bio", (cPointer, cPointer, cPointer), cVoid),
       sslSetConnectState =
         buildCall1 (sslSymbol "SSL_set_connect_state", cPointer, cVoid),
       sslCtrl =
         buildCall4 (sslSymbol "SSL_ctrl", (cPointer, cInt, cLong, cString), cLong),
       sslSet1Host = buildCall2 (sslSymbol "SSL_set1_host", (cPointer, cString), cInt),
       sslGet0Param = buildCall1 (sslSymbol "SSL_get0_param", cPointer, cPointer),
       paramSet1IpAsc =
         buildCall2
           (cryptoSymbol "X509_VERIFY_PARAM_set1_ip_asc", (cPointer, cString), cInt),
       sslDoHandshake = buildCall1 (sslSymbol "SSL_do_handshake", cPointer, cInt),
       sslGetError = buildCall2 (sslSymbol "SSL_get_error", (cPointer, cInt), cInt),
       sslRead = buildCall3 (sslSymbol "SSL_read", (cPointer, cPointer, cInt), cInt),
       sslWrite = buildCall3 (sslSymbol "SSL_write", (cPointer, cPointer, cInt), cInt),
       sslShutdown = buildCall1 (sslSymbol "SSL_shutdown", cPointer, cInt),
       sslGetVerifyResult =
         buildCall1 (sslSymbol "SSL_get_verify_result", cPointer, cLong),
       bioNewMem = fn () => bioNewRaw (bioSMem ()),
       bioWrite = buildCall3 (cryptoSymbol "BIO_write", (cPointer, cPointer, cInt), cInt),
       bioRead = buildCall3 (cryptoSymbol "BIO_read", (cPointer, cPointer, cInt), cInt),
       bioCtrl =
         buildCall4 (cryptoSymbol "BIO_ctrl", (cPointer, cInt, cLong, cPointer), cLong),
       errGetError = buildCall0 (cryptoSymbol "ERR_get_error", (), cLong),
       errErrorString =
         buildCall3
           (cryptoSymbol "ERR_error_string_n", (cLong, cPointer, cInt), cVoid)}
    end

  (* Load once, on first use, and reuse afterwards. *)
  fun api () =
    case !loaded of
        SOME existing => existing
      | NONE =>
          let
            val fresh =
              build ()
              handle exn =>
                ConvexError.fail
                  ("TransportError", "OpenSSL is unavailable: " ^ General.exnMessage exn)
          in
            loaded := SOME fresh;
            fresh
          end

  fun isNull pointer = pointer = null

  (* ---- raw byte buffers -------------------------------------------- *)

  fun withBuffer (size, body) =
    let
      val buffer = Foreign.Memory.malloc (Word.fromInt size)
      val result =
        body buffer handle exn => (Foreign.Memory.free buffer; raise exn)
    in
      Foreign.Memory.free buffer;
      result
    end

  fun putBytes (buffer, text) =
    let
      fun loop index =
        if index >= String.size text then ()
        else
          (Foreign.Memory.set8
             (buffer, Word.fromInt index,
              Word8.fromInt (Char.ord (String.sub (text, index))));
           loop (index + 1))
    in
      loop 0
    end

  fun getBytes (buffer, count) =
    CharVector.tabulate
      (count,
       fn index =>
         Char.chr (Word8.toInt (Foreign.Memory.get8 (buffer, Word.fromInt index))))

  (* Report the first queued error, which is the deepest cause, and clear the
     rest of the queue so the next operation starts clean. *)
  fun lastErrorText () =
    let
      val {errGetError, errErrorString, ...} = api ()
      val first = errGetError ()
      fun drain () = if errGetError () = 0 then () else drain ()
      val _ = drain ()
      val room = 256
    in
      if first = 0 then "no OpenSSL error detail"
      else
        withBuffer
          (room,
           fn buffer =>
             let
               val _ = errErrorString (first, buffer, room)
               fun terminator index =
                 if index >= room - 1
                    orelse Foreign.Memory.get8 (buffer, Word.fromInt index) = 0w0
                 then index
                 else terminator (index + 1)
             in
               getBytes (buffer, terminator 0)
             end)
    end
end
