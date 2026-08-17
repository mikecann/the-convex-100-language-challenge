# Objective-C

Objective-C is C with an object system inspired by Smalltalk: method calls are messages in square brackets, and objects use a dynamic runtime. Brad Cox and Tom Love created it in the early 1980s. It later became the main language for NeXT, macOS, and iOS software, so its present-day niche is largely established Apple-platform code and frameworks. Apple's archived [Programming with Objective-C](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/Introduction/Introduction.html) is the clearest official introduction.

This implementation runs on Linux using [GNUstep](https://www.gnustep.org/), an open source implementation of the Cocoa-style Foundation APIs. It is an educational, unofficial demonstration, not a production Convex SDK.

## Getting Started

The canonical [`examples/basics/main.m`](examples/basics/main.m) follows one counter from `0` to `1`: it queries the initial state, subscribes before mutating, increments once, and reads the resulting Live update.

From the repository root, run:

```sh
./run verify-example objective-c
```

That command builds and runs the exact example below in Docker against a unique test room. It proves the example journey, while the broader shared conformance commands are what support the capability claims in the Status section.

## Interesting Parts

### A method call is a sentence with the arguments woven in

Objective-C inherited its message syntax from Smalltalk rather than from C. A call isn't `name(a, b, c)`; it's a bracketed message whose keyword parts interleave with the arguments they take, so the whole invocation reads as one labeled sentence instead of a comma list. This client leans on that: every RPC keeps `args:` and `error:` right next to the values they belong to.

```objective-c
NSDictionary *arguments = @{ @"room" : @"readme-objective-c" };
NSError *error = nil;
// TypeScript: const state = useQuery(api.demo.state, { room })
CVXResult *result = [client query:@"demo:state" args:arguments error:&error];
NSNumber *count = [result.value objectForKey:@"count"];
```

Once you can hear `query:args:error:` as a single selector, the brackets stop looking like noise and start reading like a sentence.

### Failure comes back through a pointer to a pointer

There are no exceptions or `Result` enums here: every fallible call takes an `NSError **` — the address of your local `error` variable — and writes into it only if something went wrong. A `nil` return is the actual failure signal; the error object is supplementary detail the callee hands back through that extra layer of indirection.

```objective-c
NSError *error = nil;
CVXResult *mutation = [client mutation:@"demo:increment"
                                   args:mutationArguments
                                  error:&error];
if (!mutation) {
  // TypeScript: try { await client.mutation(...) } catch (e) { ... }
  fprintf(stderr, "%s\n", [[error localizedDescription] UTF8String]);
}
```

The pattern predates `Swift`-style throwing entirely, and it's still how Foundation reports errors today.

### The Live subscription is a queue you pull from by hand

React's `useQuery` subscribes and re-renders on its own timeline. This client hands you a `CVXSubscription` object instead and leaves the pulling to you: `nextUpdateWithTimeoutMilliseconds:error:` blocks the calling thread until Live delivers the next value, so a command-line program can sequence "mutate, then wait for the update" without any callback at all.

```objective-c
CVXSubscription *subscription = [client subscribe:@"demo:state"
                                               args:queryArguments
                                              error:&error];
[subscription nextUpdateWithTimeoutMilliseconds:10000 error:&error]; // initial
[client mutation:@"demo:increment" args:mutationArguments error:&error];
CVXLiveUpdate *updated =
    [subscription nextUpdateWithTimeoutMilliseconds:10000 error:&error];
[subscription unsubscribe:&error];
```

Subscribing before mutating is deliberate: it guarantees the reactive update that follows can't slip past an empty queue before anyone is listening.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, token changes, and structured errors | Verified by shared local and hosted conformance |
| Live initial values and updates through `/api/sync` | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery, and bounded delivery | Verified by shared local and hosted conformance |

The implementation is native: Convex-specific HTTP and Live behavior is written here in Objective-C and C, rather than delegated to another Convex client.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m -->
```objective-c
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

## Implementation Notes

The public surface consists of Objective-C classes and Foundation values: `CVXClient`, `CVXResult`, `CVXSubscription`, `CVXLiveUpdate`, `NSDictionary`, `NSArray`, and `NSError`. The build uses Clang 14.0.6, GNUstep Base 1.28.0, and libobjc 12 on `linux/amd64`. It uses manual reference counting, which is why the example explicitly releases the client and drains its autorelease pool. [Clang's user manual](https://clang.llvm.org/docs/UsersManual.html) documents its Objective-C language support.

Checksum-pinned libcurl 8.21.0 handles HTTP, TLS, and WebSocket transport, while json-c 0.16 parses and writes JSON behind a private C boundary. Application code sees Foundation objects, not json-c handles. Convex-specific request, subscription, reconnect, and ownership logic remains in this client, so its `native` provenance does not mean every low-level transport primitive was rewritten from scratch.

Live uses one worker to own the WebSocket and connection state. Each subscription keeps the newest 16 updates, and all subscriptions share an 8 MiB encoded-byte budget. The blocking `nextUpdateWithTimeoutMilliseconds:error:` method pulls from that bounded queue. Reconnects restore active subscriptions and suppress an unchanged rehydration value.

For local checks, `./run test objective-c` formats and compiles the source, then runs deterministic HTTP, Live, queue, deadline, and adapter fixtures in Docker. `./run build objective-c` creates the stripped non-root runtime images. The shared `verify`, `verify-hosted`, and `verify-all` commands are separate evidence gates and should be run by the repository coordinator.

The final images use a read-only root filesystem and run as user `65532:65532`. GNUstep needs temporary lock storage during startup, so `/tmp` maps to Docker's bounded `/dev/shm` tmpfs rather than persistent application storage.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations, and WebSocket actions are not implemented. Queries, mutations, actions, and token changes are available over HTTP.
2. Live follows an undocumented `/api/sync` profile pinned to a tested backend revision. That profile can drift independently of Convex's documented HTTP API.
3. A subscription retains only its newest 16 updates. One encoded Live message above 2 MiB is rejected, and all subscriptions share an 8 MiB queue budget.
4. The conformance adapter accepts at most 16 active subscriptions and abandons its controller output stream if a write remains blocked for 500 ms.
