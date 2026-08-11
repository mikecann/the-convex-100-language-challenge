# LOLCODE

[LOLCODE](http://lolcode.org/) is a playful programming language built from the
grammar of early internet cat memes. Adam Lindsay created it in 2007, and the
community turned the joke into a real language with variables, functions,
conditionals, loops, objects, and interpreters. People mainly use it for fun,
teaching, and esoteric-language experiments, which makes a complete networked
Convex client a particularly entertaining stress test.

## Getting Started

The canonical example is [`examples/basics/main.lol`](examples/basics/main.lol).
From the repository root, run:

```sh
./run verify-example lolcode
```

## Interesting Parts

### Queries look unusual, but keep the same pieces

React developers normally pass a function reference and arguments together:

```ts
const state = await convex.query(api.demo.state, { room });
```

LOLCODE uses a string path because it has no generated TypeScript API object:

```lolcode
I HAS A STATE ITZ I IZ CONVEXQUERY YR "demo:state" AN YR ARGS MKAY
```

Both calls identify a Convex function, encode an argument object, and decode the
returned value. `CONVEXQUERY` additionally preserves structured function errors
and log lines.

### Live starts before the mutation

The ordering is the same one a React component gets from `useQuery` before a
button calls a mutation:

```ts
const state = useQuery(api.demo.state, { room });
const increment = useMutation(api.demo.increment);
```

The explicit LOLCODE version makes that ordering visible:

```lolcode
I IZ CONVEXSUBSCRIBE YR "example" AN YR "demo:state" AN YR ARGS MKAY
I HAS A MUTATION ITZ I IZ CONVEXMUTATIONWITHKEY YR "demo:increment" AN YR MUTATIONARGS AN YR ROOM MKAY
```

One LOLCODE owner controls the WebSocket, query-set versions, transitions, and
reconnects. Subscribers only receive decoded events from its bounded queue.

### Integral Convex numbers are checked deliberately

JavaScript uses one number type, so this usually needs no visible conversion:

```ts
const count: number = state.count;
```

The LOLCODE helper accepts mathematically integral JSON spellings such as `0.0`
while rejecting fractions and values outside its safe integer range:

```lolcode
FOUND YR I IZ TRANSPORT'Z JSONINTEGER YR I IZ TRANSPORT'Z JSONGET YR VALUE AN YR "count" MKAY MKAY
```

## Status

| Capability | Status |
| --- | --- |
| HTTP | Pending shared verification |
| Live | Pending shared verification |

The implementation and language-local fixtures are complete, but capabilities
stay unawarded until the shared local and hosted black-box suites pass from the
reviewed commit.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.lol -->
```lolcode
HAI 1.3

BTW The verifier gives this program a unique room through the launcher. That
BTW keeps each demonstration independent without a test-only reset function.
I HAS A ROOM ITZ I IZ TRANSPORT'Z ENV YR "CONVEX_ROOM" MKAY
BOTH SAEM ROOM AN "", O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "usage: convex-example ROOM" MKAY
OIC
I HAS A ARGS ITZ "{}"
ARGS R I IZ TRANSPORT'Z JSONSET YR ARGS AN YR "room" AN YR I IZ CONVEXJSONSTRING YR ROOM MKAY MKAY

HOW IZ I EXAMPLECOUNT YR VALUE
  DIFFRINT I IZ TRANSPORT'Z JSONTYPE YR VALUE MKAY AN "object", O RLY?
    YA RLY
      FOUND YR ""
  OIC
  FOUND YR I IZ TRANSPORT'Z JSONINTEGER YR I IZ TRANSPORT'Z JSONGET YR VALUE AN YR "count" MKAY MKAY
IF U SAY SO

BTW Live events use the adapter's JSON shape. Wait for a value, while treating
BTW a structured subscription error or a deadline as a failed demonstration.
HOW IZ I EXAMPLENEXTLIVECOUNT
  I HAS A DEADLINE ITZ SUM OF TRANSPORT IZ NOW MKAY AN 15000
  IM IN YR WAITLIVE
    DIFFRINT SMALLR OF TRANSPORT IZ NOW MKAY AN DEADLINE AN TRANSPORT IZ NOW MKAY, O RLY?
      YA RLY
        I IZ TRANSPORT'Z ABORT YR "timed out waiting for Live value" MKAY
    OIC
    I HAS A EVENT ITZ I IZ CONVEXLIVETICK MKAY
    BOTH SAEM EVENT AN "", O RLY?
      YA RLY
        GTFO
    OIC
    NOT I IZ TRANSPORT'Z JSONHAS YR EVENT AN YR "value" MKAY, O RLY?
      YA RLY
        I IZ TRANSPORT'Z ABORT YR "Live subscription returned an error" MKAY
    OIC
    I HAS A COUNT ITZ I IZ EXAMPLECOUNT YR I IZ TRANSPORT'Z JSONGET YR EVENT AN YR "value" MKAY MKAY
    FOUND YR COUNT
  IM OUTTA YR WAITLIVE
  FOUND YR ""
IF U SAY SO

BTW Create the HTTP request and decode the first Convex query into an integral
BTW LOLCODE value. Decimal spellings such as 0.0 are accepted only if integral.
I HAS A FIRST ITZ I IZ CONVEXQUERY YR "demo:state" AN YR ARGS MKAY
NOT FIRST'Z OK, O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR FIRST'Z ERRORMESSAGE MKAY
OIC
DIFFRINT I IZ EXAMPLECOUNT YR FIRST'Z VALUE MKAY AN "0", O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "expected initial counter 0" MKAY
OIC

BTW Start Live before mutating and consume its initial value. This ordering
BTW proves the later change arrived through the subscription.
NOT I IZ CONVEXSUBSCRIBE YR "example" AN YR "demo:state" AN YR ARGS MKAY, O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "Live subscription could not connect" MKAY
OIC
DIFFRINT I IZ EXAMPLENEXTLIVECOUNT MKAY AN "0", O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "expected initial Live counter 0" MKAY
OIC

BTW The room is the idempotency key. The language and run ID make this
BTW mutation easy to identify while preventing the same logical retry twice.
I HAS A MUTATIONARGS ITZ ARGS
MUTATIONARGS R I IZ TRANSPORT'Z JSONSET YR MUTATIONARGS AN YR "language" AN YR I IZ CONVEXJSONSTRING YR "LOLCODE" MKAY MKAY
MUTATIONARGS R I IZ TRANSPORT'Z JSONSET YR MUTATIONARGS AN YR "runId" AN YR I IZ CONVEXJSONSTRING YR SMOOSH ROOM AN "-once" MKAY MKAY MKAY
I HAS A MUTATION ITZ I IZ CONVEXMUTATIONWITHKEY YR "demo:increment" AN YR MUTATIONARGS AN YR ROOM MKAY
NOT MUTATION'Z OK, O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR MUTATION'Z ERRORMESSAGE MKAY
OIC
NOT I IZ TRANSPORT'Z JSONEQUAL YR I IZ TRANSPORT'Z JSONGET YR MUTATION'Z VALUE AN YR "applied" MKAY AN YR "true" MKAY, O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "mutation was not applied" MKAY
OIC
I HAS A MUTATIONSTATE ITZ I IZ TRANSPORT'Z JSONGET YR MUTATION'Z VALUE AN YR "state" MKAY
DIFFRINT I IZ EXAMPLECOUNT YR MUTATIONSTATE MKAY AN "1", O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "expected mutation counter 1" MKAY
OIC

BTW Decode the resulting Live update, then issue one final HTTP query so both
BTW transports independently agree on the committed value before cleanup.
DIFFRINT I IZ EXAMPLENEXTLIVECOUNT MKAY AN "1", O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "expected updated Live counter 1" MKAY
OIC
I HAS A SECOND ITZ I IZ CONVEXQUERY YR "demo:state" AN YR ARGS MKAY
NOT SECOND'Z OK, O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR SECOND'Z ERRORMESSAGE MKAY
OIC
DIFFRINT I IZ EXAMPLECOUNT YR SECOND'Z VALUE MKAY AN "1", O RLY?
  YA RLY
    I IZ TRANSPORT'Z ABORT YR "expected final counter 1" MKAY
OIC
I IZ CONVEXCLOSELIVE MKAY

VISIBLE "current count: 0"
VISIBLE "live initial count: 0"
VISIBLE "mutation applied: true"
VISIBLE "mutation count: 1"
VISIBLE "live updated count: 1"
VISIBLE "verified count: 0 -> 1"

KTHXBYE
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The image pins official `lci` 0.11.2 at commit
`2464d0c11712ba447747492e809d6a87a3af1922` for `linux/amd64`. The client is
native by this project’s definition: Convex HTTP response handling, Live
query-set messages, transition validation, subscription state, reconnects, and
the adapter are authored in LOLCODE.

The lci extension exposes ordinary libcurl TLS, Jansson JSON tokens, OpenSSL
RFC6455 bytes, clocks, randomness, and controller-stream operations. It verifies
hostnames and certificate chains and contains no Convex-specific protocol
logic. The final Debian runtime retains the CA bundle, OpenSSL configuration,
provider modules, and shared-library closure, but no compiler, package manager,
transport CLI, Python, or Node.js command.

One owner performs all WebSocket reads, writes, query-set version changes, and
reconnects. Its output queue is globally bounded to 16 events and 4 MiB of
encoded payload. Overflow drops the oldest event, and subscription generations
prevent stale values crossing replacement or unsubscribe acknowledgements.

## Known Issues

1. HTTP and Live remain pending until the shared local and hosted conformance
   runs award them from a clean reviewed commit.
2. The demonstration targets the repository’s pinned, undocumented Convex sync
   profile and is educational code, not an officially supported SDK.
3. lci has no conventional package ecosystem for HTTP or WebSockets, so the
   ordinary TLS, JSON-token, and RFC6455 primitives live in a small C extension.
