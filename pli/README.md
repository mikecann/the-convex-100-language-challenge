# Convex from PL/I

A native Convex client written in PL/I and compiled by Iron Spring PL/I 1.4.1. It calls Convex functions over HTTP and keeps a query current over the pinned Live WebSocket profile — JSON, HTTP/1.1, RFC 6455 framing and the Convex sync state machine are all written in PL/I.

This is educational and unofficial, not a production Convex SDK.

## Start here

[`examples/basics/main.pli`](examples/basics/main.pli) follows one shared counter from 0 to 1. It reads the room with an ordinary HTTP query, opens a Live subscription to the same query *before* changing anything, applies one idempotent mutation, and then shows the Live subscription reporting the new value on its own. The final line is printed only after every step agrees.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and external updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |
| Live authentication, WebSocket mutations and actions, optimistic updates | Deferred |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pli -->
```pli
 /********************************************************************/
 /* Convex from PL/I -- the canonical introductory example.          */
 /*                                                                  */
 /* One shared counter, watched two ways at once. The program runs   */
 /* an ordinary HTTP query to read the room's current count, opens a */
 /* Live subscription to the same query, applies one mutation, and   */
 /* then shows that the Live subscription reported the change on its */
 /* own -- nobody polled for it.                                     */
 /*                                                                  */
 /* Standard out is the transcript below and nothing else; anything  */
 /* diagnostic goes to standard error.                               */
 /********************************************************************/
 main: proc options(main);

 %include convex;

 /* The PL/I runtime publishes the process arguments here, which is  */
 /* how the room name reaches the program as its first argument.     */
 dcl   1 argc_s              ext( '_pli_argc' ),
         5 argc              fixed bin(31),
         5 ppargv            ptr,
         5 ppenv             ptr;
 dcl     argslot        (0:1)ptr        based;

 dcl     envname             char(32);
 dcl     slot                fixed bin(31);
 dcl     initialcount        fixed bin(31);
 dcl     livefirst           fixed bin(31);
 dcl     liveafter           fixed bin(31);
 dcl     mutationcount       fixed bin(31);
 dcl     value               ptr;

 call cvxinit();

 /* Configuration: the deployment URL comes from the environment and */
 /* the room from the command line, so the same binary can be run    */
 /* against a local backend or a hosted one without rebuilding.      */
 envname = 'CONVEX_URL' || '00'x;
 value = c_getenv( addr(envname) );
 if value = sysnull() then call fail( 'CONVEX_URL is required' );
 if cvxseturl( value, c_strlen(value) ) = 0 then
   call fail( 'CONVEX_URL must be an http or https deployment URL' );

 call bclear( B_PATH );
 if argc > 1 then
   call bput( B_PATH, ppargv->argslot(1),
              c_strlen( ppargv->argslot(1) ) );
 else call bputt( B_PATH, 'pli-basics-demo' );

 /* Step 1: the documented HTTP query. demo:state returns the room's */
 /* record, and a room nobody has touched yet reports a count of 0.  */
 call roomargs();
 call cvxcall( 'query', addr(litstate), 10,
               bdata(B_TMP), blen(B_TMP) );
 if callok = 0 then call failcall( 'the initial HTTP query failed' );
 initialcount = countof( callvalue );
 if initialcount ^= 0 then call fail( 'this room has already been used' );
 call say( 'current count:', initialcount );

 /* Step 2: start Live before changing anything. Subscribing first   */
 /* is what makes the update at the end proof that Convex pushed it, */
 /* rather than something this program could have read back itself.  */
 slot = livesub( addr(litsub), 5,
                 addr(litstate), 10,
                 bdata(B_TMP), blen(B_TMP) );
 if slot < 0 then call fail( 'could not start the Live subscription' );

 /* The first Live delivery is the current value, so it has to agree */
 /* with the HTTP query above.                                       */
 livefirst = awaitcount( slot );
 if livefirst ^= 0 then call fail( 'the initial Live value was not 0' );
 call say( 'live initial count:', livefirst );

 /* Step 3: one mutation. runId is the idempotency key -- Convex     */
 /* records it, so re-running this program against the same room     */
 /* would report applied: false rather than counting twice.          */
 call incrementargs();
 call cvxcall( 'mutation', addr(litincrement), 14,
               bdata(B_TMP), blen(B_TMP) );
 if callok = 0 then call failcall( 'the mutation failed' );
 if jtruth( callvalue, 'applied' ) ^= 1 then
   call fail( 'the mutation reported that it did not apply' );
 call saytext( 'mutation applied: true' );
 mutationcount = countof( jmember( D_HTTP, callvalue, 'state' ) );
 if mutationcount ^= 1 then call fail( 'the mutation did not reach 1' );
 call say( 'mutation count:', mutationcount );

 /* Step 4: the Live subscription reports the new value by itself.   */
 liveafter = awaitcount( slot );
 if liveafter ^= 1 then call fail( 'the Live update was not 1' );
 call say( 'live updated count:', liveafter );

 /* Only now, with every operation agreeing, is the journey stated.  */
 call bclear( B_OUT );
 call bputt( B_OUT, 'verified count:' );
 call bputb( B_OUT, ' ' );
 call bputi( B_OUT, initialcount );
 call bputb( B_OUT, ' ' );
 call bputt( B_OUT, '->' );
 call bputb( B_OUT, ' ' );
 call bputi( B_OUT, liveafter );
 call bputb( B_OUT, '0a'x );
 call emit();

 call liveshutdown();
 return;

 /*------------------------------------------------------------------*/
 /* Helpers                                                          */
 /*------------------------------------------------------------------*/

 /* { "room": <room> } -- the argument object both demo:state and    */
 /* the Live subscription take.                                      */
 roomargs: proc;
   call bclear( B_TMP );
   call bputt( B_TMP, '{"room":"' );
   call bputesc( B_TMP, bdata(B_PATH), blen(B_PATH) );
   call bputt( B_TMP, '"}' );
   end roomargs;

 /* demo:increment also takes the language name shown in the room    */
 /* and the idempotency key that makes a repeat run a no-op.         */
 incrementargs: proc;
   call bclear( B_TMP );
   call bputt( B_TMP, '{"room":"' );
   call bputesc( B_TMP, bdata(B_PATH), blen(B_PATH) );
   call bputt( B_TMP, '","language":"PL/I","runId":"' );
   call bputesc( B_TMP, bdata(B_PATH), blen(B_PATH) );
   call bputt( B_TMP, '-once"}' );
   end incrementargs;

 /* Read the room's count. Convex sends integral numbers in decimal  */
 /* form, so 0 may arrive as 0.0; jinteger accepts that and refuses  */
 /* a genuinely fractional or out of range value.                    */
 countof: proc( node ) returns( fixed bin(31) );
   dcl   node                fixed bin(31);
   dcl   found               fixed bin(31);
   dcl   n                   fixed bin(31);
   found = jmember( D_HTTP, node, 'count' );
   if found < 0 then call fail( 'the room record had no count' );
   n = jinteger( D_HTTP, found );
   if n = -2147483647 then call fail( 'the count was not a whole number' );
   return( n );
   end countof;

 /* The same reading, for a value that arrived over Live. The Live   */
 /* value is re-parsed here because it reaches the caller as the     */
 /* exact JSON text Convex sent.                                     */
 livecountof: proc returns( fixed bin(31) );
   dcl   root                fixed bin(31);
   dcl   found               fixed bin(31);
   dcl   n                   fixed bin(31);
   root = jparse( D_TMP, bdata(B_MSG), blen(B_MSG) );
   if root < 0 then call fail( 'a Live update was not valid JSON' );
   found = jmember( D_TMP, root, 'count' );
   if found < 0 then call fail( 'a Live update had no count' );
   n = jinteger( D_TMP, found );
   if n = -2147483647 then call fail( 'a Live count was not a whole number' );
   return( n );
   end livecountof;

 jtruth: proc( node, name ) returns( fixed bin(31) );
   dcl   node                fixed bin(31);
   dcl   name                char(32);
   dcl   found               fixed bin(31);
   found = jmember( D_HTTP, node, name );
   if found < 0 then return( -1 );
   if nf( D_HTTP, found, 0 ) = J_TRUE then return( 1 );
   return( 0 );
   end jtruth;

 /* Drive the Live worker until it has an update, or give up. The    */
 /* deadline matters: a silent failure has to end the program        */
 /* rather than leave it waiting for ever.                           */
 awaitcount: proc( which ) returns( fixed bin(31) );
   dcl   which               fixed bin(31);
   dcl   deadline            fixed bin(31);
   deadline = nowms() + 30000;
   do while( nowms() < deadline );
     if livetake( which ) = 1 then do;
       if liveiserror = 1 then
         call fail( 'the Live query reported an error' );
       return( livecountof() );
       end;
     if livepump( -1, 50 ) = 0 then;
     end;
   call fail( 'no Live update arrived in time' );
   return( -1 );
   end awaitcount;

 say: proc( label, n );
   dcl   label               char(32);
   dcl   n                   fixed bin(31);
   call bclear( B_OUT );
   /* bputt stops at the last non-blank, so the separating space is  */
   /* appended as a byte rather than hidden in the literal.           */
   call bputt( B_OUT, label );
   call bputb( B_OUT, ' ' );
   call bputi( B_OUT, n );
   call bputb( B_OUT, '0a'x );
   call emit();
   end say;

 saytext: proc( t );
   dcl   t                   char(64);
   call bclear( B_OUT );
   call bputt( B_OUT, t );
   call bputb( B_OUT, '0a'x );
   call emit();
   end saytext;

 emit: proc;
   dcl   sent                fixed bin(31);
   sent = tsendall( 1, sysnull(), bdata(B_OUT), blen(B_OUT) );
   if sent = 0 then call c_exit( 74 );
   end emit;

 /* Any unexpected value ends the run non-zero, so a partial or      */
 /* wrong journey can never be mistaken for a passing example.       */
 fail: proc( why );
   dcl   why                 char(120);
   call note( why );
   call c_exit( 1 );
   end fail;

 failcall: proc( why );
   dcl   why                 char(120);
   dcl   line                char(120);
   call note( why );
   line = ' ';
   substr( line, 1, 32 ) = callerrname;
   call note( line );
   if blen(B_TMP2) > 0 then do;
     call bclear( B_OUT );
     call bput( B_OUT, bdata(B_TMP2), blen(B_TMP2) );
     call bputb( B_OUT, '0a'x );
     if tsendall( 2, sysnull(), bdata(B_OUT), blen(B_OUT) ) = 0 then;
     end;
   call c_exit( 1 );
   end failcall;

 %include convexlib;

 end main;
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test pli` builds the compiler from its pinned tarball, runs the style gate, the client unit tests and the deterministic Live tests, and exercises the adapter's real stdin/stdout behaviour. `./run verify-example pli` runs the exact example above against the approved local backend in its minimal image. `./run verify-all pli` is the shared HTTP and Live conformance gate on both the local and hosted deployments.

## How it is put together

Iron Spring PL/I produces 32-bit ELF objects and its runtime library is 32-bit, so the client binaries are i386 executables running on an amd64 image through the kernel's ia32 compatibility layer. They are linked against Debian's i386 multiarch C library and OpenSSL. Sockets, DNS, TLS, and the SHA-1, base64 and random bytes the RFC 6455 handshake needs are reached through PL/I's `OPTIONS( BYVALUE LINKAGE(SYSTEM) )` foreign-call convention; no Convex behaviour is delegated.

Two details of this compiler shaped the design more than anything else:

- **A CHAR string is capped at about 32000 characters.** An HTTP body or a Live message cannot live in one, so every payload larger than a short field is held in libc-allocated storage addressed by a pointer and a length, and PL/I reads it a byte at a time through a `BASED` overlay. A Convex value is carried as the exact JSON text it arrived as, which is also why values survive byte for byte with no PL/I value tree in the middle.
- **The runtime's start-up routine installs signal handlers with the legacy i386 `sigaction` syscall**, which Docker's default seccomp profile refuses. Every stock PL/I binary therefore dies with `SIGACTION 1 returned -1` before reaching `main` inside a container. [`client/plisig.pli`](client/plisig.pli) replaces that one routine with an `rt_sigaction` version that the profile does allow, and it is linked ahead of the vendor archive so the original is never pulled in. The compiler itself cannot be relinked, so it — and only it — runs under `qemu-i386-static` during the build.

## Protocol notes and limits

The adapter speaks NDJSON protocol v1 on stdin and stdout, or over one `ADAPTER_LISTEN` TCP connection. A single thread owns everything: the same poll loop that reads controller commands also reads the WebSocket, so reads, writes, reconnects and query-set version changes cannot interleave. Reconnection backs off from 100 ms to 15 s and resets after a successful handshake. Each reconnection resends the active `Add` operations, and an unchanged value replayed by the new connection is suppressed so a caller waiting for the next change does not see the old one.

Delivery is bounded twice: each subscription retains the newest 16 updates and drops the oldest, and the client refuses any single HTTP body or Live message above 2 MiB and holds at most 8 MiB of undelivered updates in total.

Deferred: Live authentication, WebSocket mutations and actions, optimistic updates, tagged Convex value types, and `TransitionChunk` assembly — which is treated as protocol drift that reconnects. Rehydration suppression compares values as JSON text rather than semantically, so a value the backend re-serialised differently would be republished rather than suppressed.
