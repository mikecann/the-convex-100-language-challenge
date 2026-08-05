# Convex from Objective-C

A native Objective-C client that calls Convex functions over HTTP and follows a query through the pinned `/api/sync` WebSocket profile.

This is educational and unofficial, not a production Convex SDK.

## Start here

[`examples/basics/main.m`](examples/basics/main.m) follows the shared counter from 0 to 1. It performs an HTTP query, begins Live before the mutation, uses an idempotency key, and verifies the reactive update.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, token changes, and structured errors | Implemented, awaiting root-owned shared evidence |
| Live initial values and updates through `/api/sync` | Implemented, awaiting root-owned shared evidence |
| Remove, reconnect, query-error recovery, and bounded delivery | Implemented, awaiting root-owned shared evidence |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m -->
```text
#import "ConvexClient.h"
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* Convex JSON may represent a whole count as 0 or 0.0. NSNumber keeps both
 * forms idiomatic while this check rejects fractions, infinities, and values
 * outside the exact signed 64-bit range. */
static BOOL wholeNumber(id value, long long *output) {
  if (![value isKindOfClass:[NSNumber class]])
    return NO;
  double number = [(NSNumber *)value doubleValue];
  if (!isfinite(number) || trunc(number) != number ||
      number < (double)LLONG_MIN || number > (double)LLONG_MAX)
    return NO;
  *output = [(NSNumber *)value longLongValue];
  return (double)*output == number;
}

static long long countOf(id value) {
  if (![value isKindOfClass:[NSDictionary class]])
    return -1;
  long long count = -1;
  return wholeNumber([(NSDictionary *)value objectForKey:@"count"], &count)
             ? count
             : -1;
}

static void die(CVXClient *client, NSError *error, const char *fallback) {
  NSString *message = error ? [error localizedDescription]
                            : [NSString stringWithUTF8String:fallback];
  fprintf(stderr, "%s\n", [message UTF8String]);
  [client release];
  exit(1);
}

int main(int argc, char **argv) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  const char *deployment = getenv("CONVEX_URL");
  NSString *room = argc > 1 ? [NSString stringWithUTF8String:argv[1]]
                            : @"objective-c-basic-example";
  NSError *error = nil;

  /* Configure the deployment and let the Objective-C client own all HTTP and
   * Live resources until its explicit release at the end of the journey. */
  NSURL *url =
      deployment
          ? [NSURL URLWithString:[NSString stringWithUTF8String:deployment]]
          : nil;
  CVXClient *client =
      [[CVXClient alloc] initWithDeploymentURL:url
                                 clientVersion:@"objective-c-0.2.0"
                                         error:&error];
  if (!client)
    die(client, error, "could not create client");

  /* Query the current counter over HTTP and decode its NSDictionary value. */
  NSDictionary *queryArguments = @{@"room" : room};
  CVXResult *query = [client query:@"demo:state"
                              args:queryArguments
                             error:&error];
  if (!query || countOf(query.value) != 0)
    die(client, error, "unexpected initial query value");
  printf("current count: 0\n");

  /* Start Live before the mutation so no reactive update can be missed. */
  CVXSubscription *subscription = [client subscribe:@"demo:state"
                                               args:queryArguments
                                              error:&error];
  CVXLiveUpdate *initial =
      [subscription nextUpdateWithTimeoutMilliseconds:10000 error:&error];
  if (!initial || initial.error || countOf(initial.value) != 0)
    die(client, initial.error ? initial.error : error,
        "unexpected initial Live value");
  printf("live initial count: 0\n");

  /* The run ID makes the mutation safe to retry without incrementing twice. */
  NSString *runID = [room stringByAppendingString:@"-once"];
  NSDictionary *mutationArguments = @{
    @"room" : room,
    @"language" : @"Objective-C",
    @"runId" : runID,
  };
  CVXResult *mutation = [client mutation:@"demo:increment"
                                    args:mutationArguments
                                   error:&error];
  NSDictionary *mutationValue =
      [mutation.value isKindOfClass:[NSDictionary class]] ? mutation.value
                                                          : nil;
  if (!mutation || ![[mutationValue objectForKey:@"applied"] boolValue] ||
      countOf([mutationValue objectForKey:@"state"]) != 1)
    die(client, error, "unexpected mutation result");
  printf("mutation applied: true\nmutation count: 1\n");

  /* Decode the resulting Live update, then cleanly remove the subscription. */
  CVXLiveUpdate *updated =
      [subscription nextUpdateWithTimeoutMilliseconds:10000 error:&error];
  if (!updated || updated.error || countOf(updated.value) != 1)
    die(client, updated.error ? updated.error : error,
        "unexpected updated Live value");
  printf("live updated count: 1\n");
  if (![subscription unsubscribe:&error])
    die(client, error, "unsubscribe failed");

  /* Print verification only after HTTP and Live agree on the 0 -> 1 journey. */
  printf("verified count: 0 -> 1\n");
  [client release];
  [pool drain];
  return 0;
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test objective-c` formats, compiles, and runs deterministic Objective-C client and Live fixtures inside Docker. `./run build objective-c` produces the non-root amd64 adapter runtime. Root-owned `verify-example` and conformance commands remain the capability-evidence gates.

## Protocol notes

The public API is made of real Objective-C classes and Foundation values: `CVXClient`, `CVXSubscription`, `NSDictionary`, `NSArray`, and `NSError`. It runs on GNUstep Base and libobjc on Linux. The canonical example and a deterministic local fixture both exercise that API. A private C boundary exists only so the black-box adapter can inspect exact protocol events without exposing json-c types to application code.

The adapter speaks NDJSON protocol v1 on stdin/stdout or a single `ADAPTER_LISTEN` TCP connection. Checksum-pinned libcurl 8.21.0 supplies HTTP, TLS, and WebSocket transport, while json-c 0.16 supplies the internal JSON parser. Convex-specific protocol and ownership logic remains here. One worker alone owns the socket, query-set changes, and reconnects. It resubscribes active queries after reconnect, suppresses unchanged hydration, resets backoff after a healthy connection, and reports structured function, protocol, and transport errors without stranding valid subscriptions.

The final images keep the root filesystem read-only. Their `/tmp` points at Docker's bounded `/dev/shm` runtime tmpfs because GNUstep startup under amd64 emulation needs temporary lock storage; neither client writes persistent application state there.

Live delivery keeps the newest 16 updates per subscription and also enforces a conservative shared 8 MiB encoded-byte budget. The adapter caps active subscriptions at 16. Controller output has one owner and a 500 ms write deadline, so a stopped stdin or TCP reader cannot leave generation invalidation, unsubscribe, replacement, EOF cleanup, or close blocked behind output.

Live authentication, optimistic updates, tagged Convex values, WebSocket mutations/actions, and `TransitionChunk` assembly are intentionally deferred. The sync endpoint is an undocumented pinned profile and may drift. Capability badges remain empty until the root integration task runs the shared local and hosted evidence gates from the reviewed commit.
