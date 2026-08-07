 /********************************************************************/
 /* Convex client for PL/I -- declarations.                          */
 /*                                                                  */
 /* This half of the client declares everything: the libc and        */
 /* OpenSSL entry points the transport reaches through PL/I's        */
 /* OPTIONS( BYVALUE LINKAGE(SYSTEM) ) foreign-call convention, the  */
 /* byte-buffer and JSON node shapes, and the client's own state.    */
 /* convexlib.inc holds the procedures. Both are %included into the  */
 /* program that uses them -- the canonical example, the conformance */
 /* adapter and the language-local tests -- so a program is one      */
 /* compilation unit and the client's state is the outer block's     */
 /* storage.                                                         */
 /*                                                                  */
 /* Why byte buffers instead of PL/I strings: Iron Spring PL/I 1.4.1 */
 /* caps a CHAR string at roughly 32000 characters, so an HTTP body  */
 /* or a Live message cannot be held in one. Everything larger than  */
 /* a short field therefore lives in a libc-allocated region         */
 /* addressed by a pointer and a length, and PL/I sees it one byte   */
 /* at a time through a BASED overlay.                               */
 /********************************************************************/

 dcl    (addr,substr,index,sysnull,length,mod,hbound,lbound,
         null,unspec,binaryvalue,pointervalue,ptradd)   builtin;

 /*------------------------------------------------------------------*/
 /* Byte views. Every large payload is reached through one of these  */
 /* BASED overlays rather than copied into a PL/I string.            */
 /*------------------------------------------------------------------*/
 dcl     byte1               char(1)         based;
 dcl     byte2               char(2)         based;
 dcl     byte4               char(4)         based;
 dcl     word32              fixed bin(31)   based;
 dcl     aptr                ptr             based;

 /*------------------------------------------------------------------*/
 /* libc                                                             */
 /*------------------------------------------------------------------*/
 dcl     c_write             entry( fixed bin(31), ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'write' );
 dcl     c_read              entry( fixed bin(31), ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'read' );
 dcl     c_close             entry( fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'close' );
 dcl     c_malloc            entry( fixed bin(31) )
                             returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'malloc' );
 dcl     c_realloc           entry( ptr, fixed bin(31) )
                             returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'realloc' );
 dcl     c_free              entry( ptr )
                             options( byvalue linkage(system) )
                             ext( 'free' );
 dcl     c_memcpy            entry( ptr, ptr, fixed bin(31) )
                             returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'memcpy' );
 dcl     c_memmove           entry( ptr, ptr, fixed bin(31) )
                             returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'memmove' );
 dcl     c_memcmp            entry( ptr, ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'memcmp' );
 dcl     c_strlen            entry( ptr )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'strlen' );
 dcl     c_getenv            entry( ptr )
                             returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'getenv' );
 dcl     c_exit              entry( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'exit' );
 dcl     c_getaddrinfo       entry( ptr, ptr, ptr, ptr )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'getaddrinfo' );
 dcl     c_freeaddrinfo      entry( ptr )
                             options( byvalue linkage(system) )
                             ext( 'freeaddrinfo' );
 dcl     c_socket            entry( fixed bin(31), fixed bin(31),
                                    fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'socket' );
 dcl     c_connect           entry( fixed bin(31), ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'connect' );
 dcl     c_bind              entry( fixed bin(31), ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'bind' );
 dcl     c_listen            entry( fixed bin(31), fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'listen' );
 dcl     c_accept            entry( fixed bin(31), ptr, ptr )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'accept' );
 dcl     c_setsockopt        entry( fixed bin(31), fixed bin(31),
                                    fixed bin(31), ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'setsockopt' );
 dcl     c_fcntl             entry( fixed bin(31), fixed bin(31),
                                    fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'fcntl' );
 dcl     c_poll              entry( ptr, fixed bin(31), fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'poll' );
 dcl     c_clock_gettime     entry( fixed bin(31), ptr )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'clock_gettime' );
 dcl     c_open              entry( ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'open' );
 dcl     c_errno_location    entry() returns( ptr )
                             options( byvalue linkage(system) )
                             ext( '__errno_location' );

 /*------------------------------------------------------------------*/
 /* OpenSSL. TLS, and also the SHA-1, base64 and random bytes that   */
 /* the RFC 6455 handshake needs; the framing that uses them is      */
 /* written here in PL/I.                                            */
 /*------------------------------------------------------------------*/
 dcl     TLS_client_method   entry() returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'TLS_client_method' );
 dcl     SSL_CTX_new         entry( ptr ) returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'SSL_CTX_new' );
 dcl     SSL_CTX_free        entry( ptr )
                             options( byvalue linkage(system) )
                             ext( 'SSL_CTX_free' );
 dcl     SSL_CTX_set_default_verify_paths
                             entry( ptr ) returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_CTX_set_default_verify_paths' );
 dcl     SSL_new             entry( ptr ) returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'SSL_new' );
 dcl     SSL_free            entry( ptr )
                             options( byvalue linkage(system) )
                             ext( 'SSL_free' );
 dcl     SSL_set_fd          entry( ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_set_fd' );
 dcl     SSL_ctrl            entry( ptr, fixed bin(31), fixed bin(31), ptr )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_ctrl' );
 dcl     SSL_set1_host       entry( ptr, ptr ) returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_set1_host' );
 dcl     SSL_set_verify      entry( ptr, fixed bin(31), ptr )
                             options( byvalue linkage(system) )
                             ext( 'SSL_set_verify' );
 dcl     SSL_connect         entry( ptr ) returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_connect' );
 dcl     SSL_read            entry( ptr, ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_read' );
 dcl     SSL_write           entry( ptr, ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_write' );
 dcl     ssl_geterror        entry( ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_get_error' );
 dcl     SSL_shutdown        entry( ptr ) returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_shutdown' );
 dcl     SSL_pending         entry( ptr ) returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'SSL_pending' );
 dcl     ERR_clear_error     entry()
                             options( byvalue linkage(system) )
                             ext( 'ERR_clear_error' );
 dcl     c_sha1              entry( ptr, fixed bin(31), ptr )
                             returns( ptr )
                             options( byvalue linkage(system) )
                             ext( 'SHA1' );
 dcl     EVP_EncodeBlock     entry( ptr, ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'EVP_EncodeBlock' );
 dcl     RAND_bytes          entry( ptr, fixed bin(31) )
                             returns( fixed bin(31) )
                             options( byvalue linkage(system) )
                             ext( 'RAND_bytes' );

 /*------------------------------------------------------------------*/
 /* Constants                                                        */
 /*------------------------------------------------------------------*/
 %replace AF_INET            by 2;
 %replace SOCK_STREAM        by 1;
 %replace SOL_SOCKET         by 1;
 %replace SO_REUSEADDR       by 2;
 %replace F_GETFL            by 3;
 %replace F_SETFL            by 4;
 %replace O_NONBLOCK         by 2048;    /* 04000 octal              */
 %replace POLLIN             by 1;
 %replace POLLOUT            by 4;
 %replace CLOCK_MONOTONIC    by 1;
 %replace SSL_ERROR_WANT_READ  by 2;
 %replace SSL_ERROR_WANT_WRITE by 3;
 %replace SSL_VERIFY_PEER    by 1;
 %replace SSL_CTRL_SET_TLSEXT_HOSTNAME by 55;

 /* Bounds. The container is limited to 128 MiB, so one HTTP body or */
 /* one Live message is refused above 2 MiB and each subscription    */
 /* keeps at most 16 updates.                                        */
 %replace MAX_PAYLOAD        by 2097152;
 %replace QUEUE_CAPACITY     by 16;
 %replace MAX_SUBSCRIPTIONS  by 32;
 %replace MAX_JSON_NODES     by 20000;
 %replace ADAPTER_MAX_LINE   by 2097152;

 /* JSON node kinds.                                                 */
 %replace J_NULL             by 0;
 %replace J_TRUE             by 1;
 %replace J_FALSE            by 2;
 %replace J_NUMBER           by 3;
 %replace J_STRING           by 4;
 %replace J_ARRAY            by 5;
 %replace J_OBJECT           by 6;

 /*------------------------------------------------------------------*/
 /* Client state.                                                    */
 /*                                                                  */
 /* Buffers and JSON documents are held in parallel arrays and named */
 /* by a small index. That is deliberate: this compiler cannot       */
 /* describe an array of structures living in libc storage, and an   */
 /* index keeps every procedure signature to scalars, which is also  */
 /* what avoids the adjustable dummy arguments it does not support.  */
 /*------------------------------------------------------------------*/
 %replace NBUFFERS           by 24;
 dcl     bdata     (NBUFFERS)ptr;
 dcl     blen      (NBUFFERS)fixed bin(31);
 dcl     bcap      (NBUFFERS)fixed bin(31);

 %replace B_IN               by  1;   /* adapter input, unconsumed   */
 %replace B_LINE             by  2;   /* one adapter command line    */
 %replace B_OUT              by  3;   /* one adapter event line      */
 %replace B_REQ              by  4;   /* HTTP request                */
 %replace B_RESP             by  5;   /* HTTP response body          */
 %replace B_HDR              by  6;   /* HTTP response headers       */
 %replace B_URL              by  7;
 %replace B_WSIN             by  8;   /* reassembled Live message    */
 %replace B_WSRAW            by  9;   /* unparsed WebSocket bytes    */
 %replace B_WSOUT            by 10;   /* one outgoing frame          */
 %replace B_MSG              by 11;   /* one outgoing Live message   */
 %replace B_TOKEN            by 12;   /* bearer token                */
 %replace B_TMP              by 13;
 %replace B_TMP2             by 14;
 %replace B_HOST             by 15;
 %replace B_PORT             by 16;
 %replace B_PATH             by 17;
 %replace B_TS               by 18;   /* remote timestamp            */
 %replace B_MAXTS            by 19;   /* highest timestamp observed  */
 %replace B_CLOSE            by 20;   /* last close reason           */
 %replace B_KEY              by 21;   /* Sec-WebSocket-Key           */
 %replace B_ACCEPT           by 22;
 %replace B_BODY             by 23;   /* decoded HTTP body           */
 %replace B_AUTH             by 24;

 %replace NDOCS              by 4;
 dcl     dtext       (NDOCS)ptr;
 dcl     dtlen       (NDOCS)fixed bin(31);
 dcl     dnodes      (NDOCS)ptr;
 dcl     dcount      (NDOCS)fixed bin(31);
 dcl     dcap        (NDOCS)fixed bin(31);
 dcl     dpos        (NDOCS)fixed bin(31);
 dcl     ddepth      (NDOCS)fixed bin(31);
 dcl     dok         (NDOCS)fixed bin(31);

 %replace D_CMD              by 1;    /* one adapter command         */
 %replace D_HTTP             by 2;    /* one HTTP response           */
 %replace D_WS               by 3;    /* one Live message            */
 %replace D_TMP              by 4;

 dcl     hexdigits           char(16) static init('0123456789abcdef');

 /*------------------------------------------------------------------*/
 /* Transport and call state.                                        */
 /*------------------------------------------------------------------*/
 dcl     cvxtls              fixed bin(31);   /* deployment uses TLS */
 dcl     sslctx              ptr;
 dcl     httpfd              fixed bin(31);
 dcl     httpssl             ptr;
 dcl     httpstatus          fixed bin(31);

 /* Outcome of the most recent HTTP call. A value is a node index    */
 /* into D_HTTP, so the caller reads the backend's exact JSON.       */
 dcl     callok              fixed bin(31);
 dcl     callvalue           fixed bin(31);
 dcl     calllogs            fixed bin(31);
 dcl     callerrdata         fixed bin(31);
 dcl     callerrname         char(32);

 %replace SO_RCVTIMEO        by 20;
 %replace SO_SNDTIMEO        by 21;
 %replace EAGAIN             by 11;
 %replace EINTR              by  4;
 %replace EINPROGRESS        by 115;

 /* The client identifies itself to Convex with this string.         */
 dcl     clientversion       char(16) static init('pli-0.1.0');

 /* Literals compared byte for byte rather than as PL/I strings, so   */
 /* the comparison never depends on blank padding.                    */
 dcl     litscheme_s         char(8)  static init('https://');
 dcl     litscheme_p         char(7)  static init('http://');
 dcl     litstate            char(10) static init('demo:state');
 dcl     litincrement        char(14) static init('demo:increment');
 dcl     litsub              char(5)  static init('basic');
 dcl     litflow             char(4)  static init('flow');
 dcl     litqueue            char(5)  static init('queue');
 dcl     litemptyargs        char(2)  static init('{}');

 /*------------------------------------------------------------------*/
 /* Live state.                                                      */
 /*                                                                  */
 /* One worker owns the WebSocket: this client is a single thread     */
 /* driving a poll loop, so reads, writes, reconnects and query-set   */
 /* version changes cannot interleave with each other by             */
 /* construction rather than by locking.                              */
 /*------------------------------------------------------------------*/
 dcl     wsfd                fixed bin(31);
 dcl     wsssl               ptr;
 dcl     wsconnected         fixed bin(31);
 dcl     livestarted         fixed bin(31);
 dcl     liveclosing         fixed bin(31);
 dcl     qsversion           fixed bin(31);   /* our query set version */
 dcl     remoteqs            fixed bin(31);
 dcl     remoteid            fixed bin(31);
 dcl     connectioncount     fixed bin(31);
 dcl     nextqueryid         fixed bin(31);
 dcl     reconnectat         fixed bin(31);
 dcl     backoffms           fixed bin(31);
 dcl     wsfragmented        fixed bin(31);
 dcl     wsmsgopcode         fixed bin(31);
 dcl     livefailed          fixed bin(31);

 dcl     subused   (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subqid    (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subactive (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subaddpend(MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subrempend(MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subremdone(MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subrehyd  (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subhaslast(MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     sublastp  (MAX_SUBSCRIPTIONS)ptr;
 dcl     sublastn  (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subnamep  (MAX_SUBSCRIPTIONS)ptr;
 dcl     subnamen  (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subpathp  (MAX_SUBSCRIPTIONS)ptr;
 dcl     subpathn  (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subargsp  (MAX_SUBSCRIPTIONS)ptr;
 dcl     subargsn  (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subqstart (MAX_SUBSCRIPTIONS)fixed bin(31);
 dcl     subqcount (MAX_SUBSCRIPTIONS)fixed bin(31);

 /* A queued update is already rendered JSON text: either the value  */
 /* or a complete error object. Keeping it as text is what bounds     */
 /* the queue in bytes as well as in entries, and it is the same      */
 /* representation the adapter and the example both need.             */
 dcl     qtextp    (MAX_SUBSCRIPTIONS,QUEUE_CAPACITY)ptr;
 dcl     qtextn    (MAX_SUBSCRIPTIONS,QUEUE_CAPACITY)fixed bin(31);
 dcl     qiserror  (MAX_SUBSCRIPTIONS,QUEUE_CAPACITY)fixed bin(31);
 dcl     qbytes                       fixed bin(31);
 dcl     liveiserror                  fixed bin(31);

 /* The whole client refuses to hold more than this many bytes of     */
 /* undelivered Live updates, on top of the 16 entry per subscription */
 /* bound, so a stopped reader cannot grow the process.               */
 %replace MAX_QUEUE_BYTES    by 8388608;

 %replace WS_CONT            by 0;
 %replace WS_TEXT            by 1;
 %replace WS_BINARY          by 2;
 %replace WS_CLOSE           by 8;
 %replace WS_PING            by 9;
 %replace WS_PONG            by 10;

 dcl     wsguid              char(36) static
           init('258EAFA5-E914-47DA-95CA-C5AB0DC85B11');
 dcl     initialts           char(12) static init('AAAAAAAAAAA=');
