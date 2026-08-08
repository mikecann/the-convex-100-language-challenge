NB. transport.ijs -- sockets, TLS, HTTP framing, and the small crypto/byte
NB. primitives the Convex protocol needs. Everything here is an ordinary
NB. transport dependency, not Convex-specific behavior: J's own stock
NB. jlibrary/system/main/socket.ijs supplies TCP (itself nothing but 15!:0
NB. bindings to libc), and this file adds hand-declared 15!:0 bindings
NB. straight to libssl.so.3 for TLS and to libcrypto.so.3 for SHA-1 and
NB. random bytes -- the same "call the real library directly" approach
NB. proven end to end against this project's own hosted deployment before
NB. any client source was written. There is no compiled C helper anywhere
NB. in this client: every foreign call below is declared in this file.

load jpath '~system/main/socket.ijs'
coinsert 'jsocket'

libcdm=: 1 : '(''"libc.so.6" '',u)&(15!:0)'
sslcdm=: 1 : '(''"libssl.so.3" '',u)&(15!:0)'
cryptocdm=: 1 : '(''"libcrypto.so.3" '',u)&(15!:0)'

clock_gettime_J=: 'clock_gettime i i *c' libcdm
poll_J=: 'poll i *c i i' libcdm
read_J=: 'read i i *c i' libcdm
write_J=: 'write i i *c i' libcdm

TLS_client_method_J                =: 'TLS_client_method x '                sslcdm
SSL_CTX_new_J                      =: 'SSL_CTX_new x x'                     sslcdm
SSL_CTX_set_verify_J               =: 'SSL_CTX_set_verify i x i x'          sslcdm
SSL_CTX_set_default_verify_paths_J =: 'SSL_CTX_set_default_verify_paths i x' sslcdm
SSL_new_J                          =: 'SSL_new x x'                         sslcdm
SSL_set_fd_J                       =: 'SSL_set_fd i x i'                    sslcdm
SSL_ctrl_J                         =: 'SSL_ctrl x x i x *c'                 sslcdm
SSL_set1_host_J                    =: 'SSL_set1_host i x *c'                sslcdm
SSL_connect_J                      =: 'SSL_connect i x'                     sslcdm
SSL_get_error_J                    =: 'SSL_get_error i x i'                 sslcdm
SSL_get_verify_result_J            =: 'SSL_get_verify_result x x'           sslcdm
SSL_write_J                        =: 'SSL_write i x *c i'                  sslcdm
SSL_read_J                         =: 'SSL_read i x *c i'                   sslcdm
SSL_free_J                         =: 'SSL_free i x'                        sslcdm
SSL_CTX_free_J                     =: 'SSL_CTX_free i x'                    sslcdm
SSL_shutdown_J                     =: 'SSL_shutdown i x'                    sslcdm

SHA1_J       =: 'SHA1 x *c i *c'    cryptocdm
RAND_bytes_J =: 'RAND_bytes i *c i' cryptocdm

SSL_CTRL_SET_TLSEXT_HOSTNAME=: 55
TLSEXT_NAMETYPE_host_name=: 0
SSL_VERIFY_PEER=: 1
SSL_ERROR_WANT_READ=: 2
SSL_ERROR_WANT_WRITE=: 3
SSL_ERROR_SYSCALL=: 5

first=: > @ ({.)  NB. box 0 of a cd result: the call's return value

NB. Build a clean 2-item result pair by boxing each side exactly once and
NB. catenating (never Link `;`, which splices rather than nests a side that
NB. is already a multi-item boxed value such as a connection record --
NB. json.ijs documents the same hazard for tagged values).
tx_pack=: 4 : 0
  (<x),(<y)
)

NB. ---------------------------------------------------------------------------
NB. Byte/number primitives
NB.
NB. Every one of these is a whole-array transform, not a scalar loop.
NB. ---------------------------------------------------------------------------

NB. Big-endian byte encode/decode of a non-negative integer into exactly n
NB. bytes (small integers 0-255, not characters -- callers convert to
NB. characters with `a.{~` only where they build actual wire bytes). This is
NB. wire/network byte order, for protocol fields (WebSocket frame lengths,
NB. Convex 64-bit timestamps): never for a C struct.
tx_be=: 4 : 0
  (x#256) #: y
)
tx_unbe=: 3 : 0
  256 #. y
)

NB. Little-endian counterparts, for the native-byte-order C structs this
NB. file marshals by hand (struct timespec, struct timeval): x86-64 stores
NB. multi-byte integers least-significant byte first, the opposite of the
NB. wire order above.
tx_le=: 4 : 0
  |. (x#256) #: y
)
tx_unle=: 3 : 0
  256 #. |. y
)

NB. Bytewise XOR of two equal-length byte-value lists (0-255 integers), done
NB. by decomposing each side into its 8 bits and combining bit-planes with
NB. the boolean conjunction (6 b. is XOR's truth table on 0/1 arrays), then
NB. recombining. This is the mask primitive the WebSocket layer uses, and it
NB. is a whole-array transform rather than a per-byte loop.
tx_xor=: 4 : 0
  bx=. (8#2) #: x
  by=. (8#2) #: y
  (8#2) #. bx (6 b.) by
)

NB. Base64 (RFC 4648, standard alphabet, '=' padding). Input and output are
NB. byte-value lists (0-255 integers); convert with `a.{~`/`a.i.` at the call
NB. site. Built from J's own bit/mixed-radix primitives rather than an
NB. OpenSSL BIO encoder, because it is exactly the kind of small
NB. self-contained array transform this language is meant to demonstrate.
TX_B64_ALPHABET=: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

tx_base64_encode=: 3 : 0
  n=. # y
  if. n = 0 do. '' return. end.
  pad=. 3 | -n                      NB. zero bytes needed to reach a multiple of 3
  padded=. y , pad # 0
  bits=. , (8#2) #: padded          NB. flat bitstream, MSB first, length a multiple of 24
  rows=. (# bits) % 6
  groups=. (rows,6) $ bits
  letters=. TX_B64_ALPHABET {~ 2 #. groups
  if. pad = 0 do. letters return. end.
  (((# letters) - pad) {. letters) , pad # '='
)

NB. Inverse of tx_base64_encode; y is a base64 character string (padded).
tx_base64_decode=: 3 : 0
  if. 0 = # y do. '' return. end.
  pad=. +/ y = '='
  chars=. ((# y) - pad) {. y
  vals=. TX_B64_ALPHABET i. chars
  bits=. , (6#2) #: vals
  usable=. (# bits) - 2*pad
  nbytes=. usable % 8
  (8#2) #. (nbytes,8) $ (usable {. bits)
)

NB. ---------------------------------------------------------------------------
NB. Digests and randomness (libcrypto), and a monotonic millisecond clock
NB. (libc). All three are ordinary transport-adjacent library calls, made the
NB. same way the TLS handshake below is: a direct 15!:0 binding, no shim.
NB. ---------------------------------------------------------------------------

NB. SHA-1 digest of a byte-value list (0-255 integers); result is 20
NB. byte-VALUES. cd marshals `*c` parameters as character buffers, so the
NB. input is converted to characters here and nowhere else.
tx_sha1=: 3 : 0
  text=. a. {~ y
  buf=. 20 # ' '
  r=. SHA1_J text;(#text);buf
  a. i. (20 {. > 3 { r)
)

NB. n cryptographically random byte-values (0-255 integers).
tx_random_bytes=: 3 : 0
  buf=. y # ' '
  r=. RAND_bytes_J buf;y
  ok=. first r
  if. ok ~: 1 do. '' return. end.
  a. i. (y {. > 1 { r)
)

NB. RFC 4122 version-4 UUID string, used as the Live sync session id. Amend
NB. (`newvalue (index}) array`) patches the version nibble and variant bits
NB. into the 16 random bytes in place.
tx_uuid=: 3 : 0
  b=. tx_random_bytes 16
  b=. (64 + 16 | 6 { b) (6}) b   NB. version nibble -> 0100
  b=. (128 + 64 | 8 { b) (8}) b NB. variant bits -> 10xx xxxx
  hex=. ,'0123456789abcdef' {~ (16 16) #: b
  (8{.hex),'-',(4{.8}.hex),'-',(4{.12}.hex),'-',(4{.16}.hex),'-',(12{.20}.hex)
)

NB. Monotonic milliseconds since an arbitrary epoch (CLOCK_MONOTONIC), used
NB. for every deadline in this client. `struct timespec` is two 8-byte
NB. fields on x86-64; only the low bytes of tv_nsec are needed at
NB. millisecond resolution, so the readback is truncated after conversion.
tx_now_ms=: 3 : 0
  buf=. 16 # ' '
  r=. clock_gettime_J 1;buf
  raw=. a. i. > 2 { r
  secs=. tx_unle 8 {. raw
  nsecs=. tx_unle 8 }. raw
  (secs * 1000) + (<. nsecs % 1000000)
)

NB. Remaining milliseconds until an absolute tx_now_ms-scale deadline, never
NB. negative -- every bounded read/write below asks for this, not a fixed
NB. timeout, so a slow first half of an exchange shortens what is left for
NB. the second half instead of resetting the clock.
tx_remaining=: 3 : 0
  left=. y - tx_now_ms ''
  0 >. left
)

NB. ---------------------------------------------------------------------------
NB. Deadline-bounded plain and TLS connections
NB.
NB. A connection is a tagged boxed record so plain and TLS sockets share one
NB. calling convention: (<'plain'),(<fd) or (<'tls'),(<fd),(<sslptr),(<ctxptr).
NB. Both kinds honour a millisecond deadline on every send/recv by setting
NB. SO_RCVTIMEO/SO_SNDTIMEO before the call: a blocking socket with a receive
NB. timeout returns EAGAIN/EWOULDBLOCK when the deadline passes, which is
NB. surfaced here as a timeout rather than silently retried.
NB. ---------------------------------------------------------------------------

TX_IO_OK=: 1
TX_IO_TIMEOUT=: 0
TX_IO_EOF=: _1
TX_IO_ERROR=: _2

tx_le8=: 8&tx_le

NB. Build the raw 16-byte struct timeval for SO_RCVTIMEO/SO_SNDTIMEO from a
NB. millisecond count.
tx_timeval=: 3 : 0
  ms=. 1 >. y  NB. never zero: a zero timeval means "block forever" to the kernel
  secs=. <. ms % 1000
  NB. The millisecond remainder converted to microseconds -- 1000*(ms-secs)
  NB. (no missing factor of 1000 on secs) computed the wrong thing for any
  NB. ms >= 1000: at ms=1500 it produced usecs=1499000, out of a timeval's
  NB. valid 0-999999 range, rather than the intended 500000. setsockopt
  NB. silently no-ops on an out-of-range tv_usec on this platform rather
  NB. than erroring (its result was never checked here either), so the
  NB. previously-set timeout -- or an unset, block-forever default -- stayed
  NB. in effect instead. That is what made every large-budget probe during
  NB. this bug's investigation "work": SO_RCVTIMEO was never really being
  NB. applied, so reads just blocked until real data arrived.
  usecs=. 1000 * ms - (1000 * secs)
  a. {~ (tx_le8 secs) , tx_le8 usecs
)

tx_set_timeout=: 3 : 0
  'sock which ms'=. y
  setsockoptJ sock;SOL_SOCKET;which;(tx_timeval ms);16
)

tx_connect=: 4 : 0
  'host port secure'=. x
  deadline=. (tx_now_ms '') + y
  'rc s'=. sdsocket ''
  if. rc ~: 0 do. TX_IO_ERROR;'socket() failed' return. end.
  'rc fam ip'=. sdgethostbyname host
  if. rc ~: 0 do. (sdclose s) ] (TX_IO_ERROR;'DNS resolution failed for ',host) return. end.
  result=. sdconnect s;AF_INET;ip;port
  if. 0 ~: {. result do. (sdclose s) ] (TX_IO_ERROR;'TCP connect failed') return. end.
  if. -. secure do.
    TX_IO_OK tx_pack (<'plain'),(<s) return.
  end.
  tx_tls_handshake s;host;deadline
)

tx_tls_handshake=: 3 : 0
  's host deadline'=. y
  method=. first TLS_client_method_J ''
  ctx=. first SSL_CTX_new_J <method
  if. ctx = 0 do. (sdclose s) ] (TX_IO_ERROR;'SSL_CTX_new failed') return. end.
  SSL_CTX_set_verify_J ctx;SSL_VERIFY_PEER;0
  vp=. first SSL_CTX_set_default_verify_paths_J <ctx
  if. vp ~: 1 do.
    SSL_CTX_free_J <ctx [ sdclose s
    TX_IO_ERROR;'no CA trust store could be loaded' return.
  end.
  ssl=. first SSL_new_J <ctx
  if. ssl = 0 do. SSL_CTX_free_J <ctx
  sdclose s
  (TX_IO_ERROR;'SSL_new failed') return. end.
  SSL_set_fd_J ssl;s
  SSL_ctrl_J ssl;SSL_CTRL_SET_TLSEXT_HOSTNAME;TLSEXT_NAMETYPE_host_name;host
  hok=. first SSL_set1_host_J ssl;host
  if. hok ~: 1 do.
    SSL_free_J <ssl [ SSL_CTX_free_J <ctx [ sdclose s
    TX_IO_ERROR;'SSL_set1_host failed' return.
  end.
  NB. SSL_connect runs over a blocking fd carrying its own SO_RCVTIMEO /
  NB. SO_SNDTIMEO: OpenSSL cannot tell that from a genuinely non-blocking
  NB. fd, so a read or write that hits the per-call timeout is reported as
  NB. WANT_READ / WANT_WRITE rather than a hard failure. Retrying is exactly
  NB. what a non-blocking caller would do, bounded by the same deadline
  NB. every other step in this handshake already honours.
  cr=. 0
  while. cr ~: 1 do.
    if. (tx_remaining deadline) = 0 do.
      SSL_free_J <ssl [ SSL_CTX_free_J <ctx [ sdclose s
      TX_IO_TIMEOUT;'TLS handshake timed out' return.
    end.
    tx_set_timeout s;SO_RCVTIMEO;tx_remaining deadline
    tx_set_timeout s;SO_SNDTIMEO;tx_remaining deadline
    cr=. first SSL_connect_J <ssl
    if. cr ~: 1 do.
      err=. first SSL_get_error_J ssl;cr
      if. -. (err = SSL_ERROR_WANT_READ) +. err = SSL_ERROR_WANT_WRITE do.
        SSL_free_J <ssl [ SSL_CTX_free_J <ctx [ sdclose s
        TX_IO_ERROR;'TLS handshake failed (SSL_get_error=',(": err),')' return.
      end.
    end.
  end.
  verify=. first SSL_get_verify_result_J <ssl
  if. verify ~: 0 do.
    SSL_shutdown_J <ssl [ SSL_free_J <ssl [ SSL_CTX_free_J <ctx [ sdclose s
    TX_IO_ERROR;'certificate verification failed (X509 code ',(": verify),')' return.
  end.
  TX_IO_OK tx_pack (<'tls'),(<s),(<ssl),(<ctx)
)

tx_kind=: 3 : 0
  > 0 { y
)

NB. Send the whole of `data` (a byte-value list) within `ms` milliseconds.
NB. y is (<conn);data;ms -- conn arrives pre-boxed by the caller (it is
NB. itself a multi-item record), so it is pulled out here with an explicit
NB. index rather than a multi-name assignment. Multi-name assignment opens a
NB. boxed item that holds a single atom but leaves a box holding a
NB. multi-item record unopened, which silently handed this verb a boxed
NB. connection record instead of the record itself.
tx_send=: 3 : 0
  conn=. > 0 { y
  data=. > 1 { y
  ms=. > 2 { y
  deadline=. (tx_now_ms '') + ms
  s=. > 1 { conn
  text=. a. {~ data
  if. 'plain' -: tx_kind conn do.
    tx_set_timeout s;SO_SNDTIMEO;tx_remaining deadline
    r=. text sdsend s;0
    NB. sdsend always Link-boxes its result (0;bytesSent on success,
    NB. 0;~sdsockerror'' on failure) -- unlike sdconnect/sdbind/sdlisten,
    NB. which return a bare unboxed 0 through rc0 on success. {. r would
    NB. take the still-boxed first item, and a boxed 0 is never ~: to a
    NB. plain 0, so every successful send was wrongly read as a failure
    NB. the first time this path ran against a plain (non-TLS) backend --
    NB. every prior test exercised only the TLS branch below. first r
    NB. opens the box before comparing, matching how the cd-result helper
    NB. above the FFI declarations already does the same unboxing.
    if. 0 ~: first r do. TX_IO_ERROR;'write failed' return. end.
    TX_IO_OK;'' return.
  end.
  ssl=. > 2 { conn
  sent=. 0
  while. sent < # text do.
    remaining=. tx_remaining deadline
    if. remaining = 0 do. TX_IO_TIMEOUT;'' return. end.
    tx_set_timeout s;SO_SNDTIMEO;remaining
    chunk=. sent }. text
    wr=. SSL_write_J ssl;chunk;(# chunk)
    n=. first wr
    if. n > 0 do.
      sent=. sent + n
    else.
      err=. first SSL_get_error_J ssl;n
      if. (err = SSL_ERROR_WANT_READ) +. err = SSL_ERROR_WANT_WRITE do. continue. end.
      TX_IO_ERROR;'TLS write failed (SSL_get_error=',(": err),')' return.
    end.
  end.
  TX_IO_OK;''
)

NB. Read up to `limit` bytes within `ms` milliseconds. Result is
NB. status;bytes where bytes is a byte-value list (never characters, so a
NB. caller can tell EOF/timeout apart from a genuine empty read at the type
NB. level as well as the status code). y is (<conn);limit;ms -- see tx_send
NB. for why conn is pulled out by explicit index rather than multi-name
NB. assignment.
tx_recv=: 3 : 0
  conn=. > 0 { y
  limit=. > 1 { y
  ms=. > 2 { y
  deadline=. (tx_now_ms '') + ms
  s=. > 1 { conn
  if. 'plain' -: tx_kind conn do.
    NB. Wait for readability with poll() -- this client's own 15!:0 binding,
    NB. already trusted for the adapter's stdio transport -- instead of
    NB. leaning on sdrecv's SO_RCVTIMEO. A short-but-valid SO_RCVTIMEO here
    NB. (proven with the deployment's own real sync connection, not a
    NB. synthetic fixture: a live subscription over a plain, non-TLS
    NB. connection with a sub-second read budget) made a genuine "no data
    NB. yet" timeout come back from sdrecv indistinguishable from a
    NB. peer-closed socket -- c=0, the same shape as a real EOF -- so every
    NB. read that had to wait out its budget tore down a connection the
    NB. deployment's own logs showed was never actually closed ("Connection
    NB. reset without closing handshake: Client disconnected", logged at
    NB. the exact moment tx_close ran on a socket poll() would have called
    NB. healthy). Large budgets never surfaced this because they were long
    NB. enough for real data to always win the race against the timeout.
    NB. poll()'s own timeout is unambiguous -- it reports not-ready, never
    NB. a fabricated EOF -- so the timeout decision happens here, before
    NB. sdrecv is ever called, and sdrecv only runs once data is confirmed
    NB. waiting.
    if. -. tx_poll_ready s;1;tx_remaining deadline do. TX_IO_TIMEOUT;'' return. end.
    r=. sdrecv s;limit;0
    NB. sdrecv Link-boxes its result, and the two shapes are not even the
    NB. same type: 0;data on success, '';~sdsockerror'' on failure/timeout
    NB. (the first item is the empty string itself, not a negative number
    NB. -- {.r<0, the original check here, compared a still-boxed value
    NB. with a relational operator, which this codebase's own TLS branch
    NB. never does; = / ~: tolerate box-vs-atom, < does not). first opens
    NB. the box, and -: (Match) compares the opened value against '' by
    NB. shape and content rather than assuming it is numeric.
    rc=. first r
    if. rc -: '' do. TX_IO_TIMEOUT;'' return. end.
    data=. > 1 { r
    if. 0 = # data do. TX_IO_EOF;'' return. end.
    TX_IO_OK;(a. i. data) return.
  end.
  ssl=. > 2 { conn
  remaining=. tx_remaining deadline
  if. remaining = 0 do. TX_IO_TIMEOUT;'' return. end.
  tx_set_timeout s;SO_RCVTIMEO;remaining
  buf=. limit # ' '
  rr=. SSL_read_J ssl;buf;limit
  n=. first rr
  if. n > 0 do.
    TX_IO_OK;(a. i. (n {. > 2 { rr)) return.
  end.
  err=. first SSL_get_error_J ssl;n
  NB. A blocking fd with SO_RCVTIMEO cannot signal "no data within the
  NB. deadline" any other way to OpenSSL: WANT_READ/WANT_WRITE and the
  NB. generic SYSCALL code (with no queued OS error) all mean the same
  NB. thing here that they would for a plain socket -- the read timed out.
  NB. Callers already poll this in a loop, so no retry belongs in here.
  if. (err = SSL_ERROR_WANT_READ) +. (err = SSL_ERROR_WANT_WRITE) +. err = SSL_ERROR_SYSCALL do.
    TX_IO_TIMEOUT;'' return.
  end.
  if. n = 0 do. TX_IO_EOF;'' return. end.
  TX_IO_ERROR;'TLS read failed (SSL_get_error=',(": err),')'
)

NB. `2!:5` returns the scalar atom 0 (rank 0, numeric) for an unset
NB. variable rather than an empty string, and concatenating that with a
NB. character string is a domain error; normalise to a proper character
NB. string here once, by rank rather than length (an empty *string* is
NB. still rank 1).
tx_getenv=: 3 : 0
  v=. 2!:5 y
  if. 0 = # $ v do. '' return. end.
  v
)

tx_close=: 3 : 0
  NB. A 'stdio' connection wraps file descriptors the process inherited
  NB. rather than a socket this client opened, so closing it here would be
  NB. wrong even where it would be harmless; only 'plain' and 'tls' sockets
  NB. are ever this client's own to close.
  if. 'stdio' -: tx_kind y do. i. 0 return. end.
  s=. > 1 { y
  if. 'tls' -: tx_kind y do.
    ssl=. > 2 { y
    ctx=. > 3 { y
    SSL_shutdown_J <ssl
    SSL_free_J <ssl
    SSL_CTX_free_J <ctx
  end.
  sdclose s
  i. 0
)

NB. ---------------------------------------------------------------------------
NB. stdio connections
NB.
NB. The NDJSON adapter's default transport is a pair of inherited file
NB. descriptors, not a socket: setsockopt (and so tx_send/tx_recv's
NB. SO_RCVTIMEO/SO_SNDTIMEO deadline) fails with ENOTSOCK on a pipe or a
NB. terminal. Deadlines here are enforced with poll() instead, the same
NB. primitive a non-blocking caller would reach for on any Unix fd.
NB. ---------------------------------------------------------------------------

NB. struct pollfd on x86-64: { int fd; short events; short revents; } is 8
NB. bytes with no padding (4 + 2 + 2). POLLIN=1, POLLOUT=4.
tx_poll_ready=: 3 : 0
  'fd events ms'=. y
  fdbytes=. 4 tx_le fd
  evbytes=. 2 tx_le events
  rvbytes=. 2 tx_le 0
  pfd=. a. {~ fdbytes , evbytes , rvbytes
  r=. poll_J pfd;1;ms
  n=. first r
  n > 0
)

NB. y is (<'stdio'),(<infd),(<outfd). Result is (<status),(<bytes).
tx_stdio_recv=: 3 : 0
  conn=. > 0 { y
  limit=. > 1 { y
  ms=. > 2 { y
  infd=. > 1 { conn
  if. -. tx_poll_ready infd;1;ms do. (<TX_IO_TIMEOUT),(<'') return. end.
  buf=. limit # ' '
  r=. read_J infd;buf;limit
  n=. first r
  if. n > 0 do. (<TX_IO_OK),(<(a. i. (n {. > 2 { r))) return. end.
  if. n = 0 do. (<TX_IO_EOF),(<'') return. end.
  (<TX_IO_ERROR),(<'')
)

NB. y is (<'stdio'),(<infd),(<outfd). Sends the whole of `data` (a
NB. byte-value list), retrying short writes until the deadline.
tx_stdio_send=: 3 : 0
  conn=. > 0 { y
  data=. > 1 { y
  ms=. > 2 { y
  outfd=. > 2 { conn
  text=. a. {~ data
  deadline=. (tx_now_ms '') + ms
  sent=. 0
  while. sent < # text do.
    remaining=. tx_remaining deadline
    if. remaining = 0 do. (<TX_IO_TIMEOUT),(<'') return. end.
    if. -. tx_poll_ready outfd;4;remaining do. continue. end.
    chunk=. sent }. text
    r=. write_J outfd;chunk;(# chunk)
    n=. first r
    if. n > 0 do.
      sent=. sent + n
    else.
      (<TX_IO_ERROR),(<'') return.
    end.
  end.
  (<TX_IO_OK),(<'')
)
