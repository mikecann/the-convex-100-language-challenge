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
