\ convex-error.fth - the structured failure Convex needs, expressed in Forth.
\
\ Forth's THROW carries a single integer. Convex distinguishes a function that
\ returned an error, a protocol violation and a transport failure, and the
\ conformance adapter has to report the name, message and error data of each
\ without flattening them into a successful value. This file keeps one
\ structured error record beside THROW, so a failure keeps its shape all the
\ way from the socket to the adapter's NDJSON output.
\
\ There is exactly one record because the client is single threaded by design:
\ one owner touches the socket, and a failure is consumed by the word that
\ caught it before another can be raised.

require convex-config.fth

\ Distinctive THROW code. Anything else reaching a catch site is a genuine
\ Forth fault (allocation failure, file error) and is reported as such rather
\ than being mistaken for a Convex error.
-30000 constant cvx-error-code

\ A fixed-size text slot: [maximum][length][bytes]. Fixed sizes keep the error
\ path allocation free, which matters because errors are raised from the
\ out-of-memory guards themselves.
: string-slot ( maximum "name" -- )
    create dup , 0 , allot ;

: slot-max ( slot -- u )  @ ;
: slot-len ( slot -- u )  cell+ @ ;
: slot-data ( slot -- addr )  2 cells + ;
: slot@ ( slot -- addr u )  dup slot-data swap slot-len ;
: slot-reset ( slot -- )  0 swap cell+ ! ;

\ Overlong text is truncated rather than raising, because raising here would
\ recurse while a failure is already being reported.
: slot! ( addr u slot -- )
    { source count slot }
    count slot slot-max min to count
    source slot slot-data count move
    count slot cell+ ! ;

: slot+ ( addr u slot -- )
    { source count slot }
    slot slot-max slot slot-len - count min to count
    count 0= if exit then
    source slot slot-data slot slot-len + count move
    count slot slot-len + slot cell+ ! ;

64 string-slot cvx-error-name
512 string-slot cvx-error-message
1024 string-slot cvx-error-data     \ JSON text, empty when the error carries none
4096 string-slot cvx-error-logs     \ JSON array text, empty when unknown
32 string-slot cvx-error-op         \ query, mutation, action or subscribe

\ The operation in flight. Recorded once at the start of a call so that every
\ error raised underneath it carries the operation without each raise site
\ having to remember, and without a reset losing it.
32 string-slot cvx-current-op

\ Scratch used to compose a message before raising. Kept separate from the
\ record so composing a message never clobbers an error being reported.
1024 string-slot cvx-message-scratch

: msg-start ( -- )  cvx-message-scratch slot-reset ;
: msg+ ( addr u -- )  cvx-message-scratch slot+ ;
\ Formats inline rather than calling convex-buffer's u>string: convex-buffer
\ requires this file for its own error slots, so this file cannot require
\ convex-buffer back without a cycle.
: msg+u ( u -- )  0 <# #s #> msg+ ;
: msg@ ( -- addr u )  cvx-message-scratch slot@ ;

: cvx-error-reset ( -- )
    cvx-error-name slot-reset
    cvx-error-message slot-reset
    cvx-error-data slot-reset
    cvx-error-logs slot-reset
    cvx-error-op slot-reset ;

: cvx-error-name! ( addr u -- )  cvx-error-name slot! ;
: cvx-error-message! ( addr u -- )  cvx-error-message slot! ;
: cvx-error-data! ( addr u -- )  cvx-error-data slot! ;
: cvx-error-logs! ( addr u -- )  cvx-error-logs slot! ;
: cvx-error-op! ( addr u -- )  cvx-error-op slot! ;

: cvx-error-name@ ( -- addr u )  cvx-error-name slot@ ;
: cvx-error-message@ ( -- addr u )  cvx-error-message slot@ ;
: cvx-error-data@ ( -- addr u )  cvx-error-data slot@ ;
: cvx-error-logs@ ( -- addr u )  cvx-error-logs slot@ ;
: cvx-error-op@ ( -- addr u )  cvx-error-op slot@ ;

\ Raise a structured Convex error. The three names below are the only ones the
\ shared adapter schema and the conformance controller ever see.
: cvx-operation! ( addr u -- )  cvx-current-op slot! ;
: cvx-operation@ ( -- addr u )  cvx-current-op slot@ ;

: cvx-raise ( name-addr name-u message-addr message-u -- )
    { name-addr name-count message-addr message-count }
    cvx-error-reset
    name-addr name-count cvx-error-name!
    message-addr message-count cvx-error-message!
    cvx-operation@ cvx-error-op!
    cvx-error-code throw ;

: cvx-raise-transport ( addr u -- )  s" TransportError" 2swap cvx-raise ;
: cvx-raise-protocol ( addr u -- )  s" ProtocolError" 2swap cvx-raise ;
: cvx-raise-function ( addr u -- )  s" FunctionError" 2swap cvx-raise ;

\ Raise using whatever was composed with msg-start / msg+.
: cvx-raise-msg ( name-addr name-u -- )  msg@ cvx-raise ;

\ True when a caught THROW code is a structured Convex error rather than an
\ ordinary Forth fault. A plain Forth fault is turned into a TransportError so
\ nothing escapes the adapter unlabelled.
: cvx-error? ( code -- flag )  cvx-error-code = ;

: cvx-adopt-fault ( code -- )
    dup cvx-error? if drop exit then
    msg-start s" client fault " msg+ abs msg+u
    cvx-error-reset
    s" TransportError" cvx-error-name!
    msg@ cvx-error-message!
    cvx-operation@ cvx-error-op! ;
