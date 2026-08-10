# PL/I

PL/I, pronounced "P-L one", is IBM's general-purpose language for both
commercial and scientific work. It first appeared in 1964 and sits in the same
compiled, procedural family a modern developer might associate with COBOL and
Fortran, while also supporting calls into C. Today its clearest home is
maintaining and modernising applications on IBM Z and AIX. IBM's
[PL/I overview](https://www.ibm.com/docs/en/zos-basic-skills?topic=zos-pli),
[compiler family](https://www.ibm.com/products/pli-compiler-family), and
[language timeline](https://www.ibm.com/ibm/files/S608123Y18657C60/us__en_us__ibm100__fortran__computer_language_evolution.pdf)
give useful official context.

This repository takes it somewhere much less expected: a native Convex client
compiled with [Iron Spring PL/I 1.4.1](https://www.iron-spring.com/readme_linux.html).
It is an educational, unofficial demonstration, not a production Convex SDK.

## Getting Started

Start with [`examples/basics/main.pli`](examples/basics/main.pli). It queries a
new room, subscribes to that same room, increments the counter once, and waits
for Convex to push the updated value.

From the repository root, run:

```sh
./run verify-example pli
```

The command builds and runs the canonical example in Docker against a unique
test room. You do not need a PL/I compiler installed on your machine.

## Interesting Parts

### Arguments are objects in React and bytes here

In React, generated Convex types make the mutation arguments and return value
ordinary TypeScript objects:

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

function IncrementOnce() {
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={async () => {
        const result = await increment({
          room: "readme-pli",
          language: "TypeScript",
          // One fresh key per click, reused if that call is retried.
          runId: crypto.randomUUID(),
        });
        console.log(result.state.count); // The result is type-safe here.
      }}
    >
      Increment
    </button>
  );
}
```

Iron Spring's fixed `CHAR` values are blank padded and limited to roughly
32,000 characters. This client therefore assembles the same argument object in
a growable byte buffer before making the HTTP mutation:

**PL/I**

```pli
%include convex; /* The client API, buffers, and result fields. */

dcl mutationpath char(14) init('demo:increment');
dcl mutationcount fixed bin(31);
dcl statenode fixed bin(31);
dcl countnode fixed bin(31);

/* Build the exact JSON object Convex expects, without CHAR padding. */
call bclear( B_TMP );
call bputt( B_TMP, '{"room":"readme-pli",' );
call bputt( B_TMP, '"language":"PL/I",' );
/* This focused program makes one logical call, so its key stays fixed. */
call bputt( B_TMP, '"runId":"readme-pli-once"}' );

/* The real client posts this mutation and parses the JSON response. */
call cvxcall( 'mutation', addr(mutationpath), 14,
              bdata(B_TMP), blen(B_TMP) );
if callok = 0 then call c_exit( 1 );

/* A returned value is a JSON node index, so fields are explicit. */
statenode = jmember( D_HTTP, callvalue, 'state' );
countnode = jmember( D_HTTP, statenode, 'count' );
mutationcount = jinteger( D_HTTP, countnode );
```

This is not how every PL/I API must look. It is a client design shaped by this
compiler's string model and by the need to preserve arbitrary Convex JSON.
The React handler creates a fresh idempotency key for each click. This PL/I
fragment represents one process invocation, so its fixed key safely identifies
that one logical call and any retry of it. The canonical example derives its
stable `runId` from the verifier's unique room. Its exact builder is in
[`main.pli`](examples/basics/main.pli).

### React hides the subscription loop

`useQuery` owns a subscription for the lifetime of the component. When the
mutation changes the room, React renders again with the pushed value:

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function Counter() {
  const room = "readme-pli-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <p>Loading...</p>;

  return (
    <button
      onClick={() =>
        increment({
          room,
          language: "TypeScript",
          // Each click is a new logical increment with its own retry key.
          runId: crypto.randomUUID(),
        })
      }
    >
      {state.count} {/* A pushed update causes this component to render again. */}
    </button>
  );
}
```

A command-line PL/I program has no component lifecycle, so this client exposes
the subscription and its event loop directly:

**PL/I**

```pli
%include convex; /* The client API, buffers, and subscription state. */

dcl statepath char(10) init('demo:state');
dcl subname char(5) init('basic');
dcl slot fixed bin(31);
dcl envname char(32);
dcl deployment ptr;

call cvxinit();                 /* Initialise all client-owned state. */
envname = 'CONVEX_URL' || '00'x;
deployment = c_getenv( addr(envname) );
/* Configure the deployment selected by the Docker verifier. */
if deployment = sysnull() then call c_exit( 1 );
if cvxseturl( deployment, c_strlen(deployment) ) = 0 then
  call c_exit( 1 );

call bclear( B_TMP );
call bputt( B_TMP, '{"room":"readme-pli-live"}' );

/* Subscribe before the mutation so the later value is a pushed update. */
slot = livesub( addr(subname), 5, addr(statepath), 10,
                bdata(B_TMP), blen(B_TMP) );

/* livepump advances the socket; livetake removes one queued delivery. */
do while( livetake( slot ) = 0 );
  if livepump( -1, 50 ) = 0 then;
  end;
/* B_MSG now contains the initial demo:state value as JSON text. */

/* The full example performs demo:increment here, then waits again. */
do while( livetake( slot ) = 0 );
  if livepump( -1, 50 ) = 0 then;
  end;
/* B_MSG now contains the pushed state after the mutation. */

call liveshutdown();            /* Dispose of subscriptions and the socket. */
```

PL/I has broader event and multitasking facilities. The explicit `livepump`
and blocking `livetake` pairing is this client's small, deterministic API, not
a language restriction. The complete example adds deadlines, decoding, and
value checks around this focused lifecycle.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and external updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |
| Live authentication, WebSocket mutations and actions, optimistic updates | Deferred |

## Example

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

## Implementation Notes

This is a native implementation. PL/I owns the Convex JSON handling, HTTP/1.1
framing, WebSocket framing, and Live state. It calls libc for sockets and DNS,
and OpenSSL for TLS plus the cryptographic pieces of the WebSocket handshake.
It does not delegate Convex behaviour to another SDK or runtime.

Iron Spring PL/I 1.4.1 emits 32-bit i386 programs. Docker still provides a real
`linux/amd64` image, and the final example and adapter run through the kernel's
i386 compatibility support with Debian's 32-bit C and OpenSSL libraries. The
compiler alone runs through QEMU during the build because its stock startup
code uses a legacy signal syscall blocked by Docker. The shipped programs link
[`client/plisig.pli`](client/plisig.pli), a small replacement that uses the
allowed signal interface.

Large values live in libc-allocated buffers because of the compiler's fixed
string limit. The parser records offsets into the original JSON rather than
building a PL/I object tree, so values can pass through without changing large
numbers or object order. Callers explicitly decode the fields they need.

One poll loop owns all Live reads, writes, reconnects, and subscription
changes. Each subscription keeps the newest 16 deliveries, the whole client
allows at most 8 MiB of queued deliveries, and any one HTTP response or Live
message is capped at 2 MiB. On reconnect, active subscriptions are sent again
and an unchanged replay is suppressed.

The evidence-backed Docker gates are deliberately separate:

- `./run test pli` checks style, unit behaviour, deterministic Live behaviour,
  compilation, and the adapter inside Docker.
- `./run verify-example pli` runs the exact example above against a unique room.
- `./run verify pli` adds shared local HTTP and Live conformance.
- `./run verify-hosted pli` repeats the shared checks against the hosted target.
- `./run verify-all pli` runs both deployment profiles from the same source.

## Known Issues

1. Live authentication, WebSocket mutations and actions, and optimistic updates
   are deferred. HTTP authentication replacement is verified.
2. Live values support the JSON-safe subset. Tagged Convex value types are not
   decoded yet.
3. `TransitionChunk` assembly is not implemented. Receiving one is treated as
   protocol drift and causes a reconnect.
4. Reconnect replay suppression compares JSON text, not semantic values. If the
   backend serialises an unchanged object differently, the client republishes
   it.
5. Payload and queue limits are intentional. An individual HTTP response or
   Live message over 2 MiB is rejected, and a slow reader loses older updates
   once its 16-entry subscription queue fills.
