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

### A familiar query becomes a message to an object

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "readme-objective-c" });
  return <p>{state === undefined ? "Loading..." : state.count}</p>;
}
```

**Objective-C**

```objective-c
#import "ConvexClient.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  const char *deployment = getenv("CONVEX_URL");
  if (!deployment) {
    fprintf(stderr, "CONVEX_URL is required\n");
    [pool drain];
    return 1;
  }
  // Convert the deployment setting into a Foundation URL, then create a client.
  NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:deployment]];
  NSError *error = nil;
  CVXClient *client = [[CVXClient alloc] initWithDeploymentURL:url
                                                clientVersion:@"readme-example"
                                                        error:&error];

  // NSDictionary is the Objective-C argument object for { room: ... }.
  NSDictionary *arguments = @{ @"room" : @"readme-objective-c" };
  CVXResult *result = [client query:@"demo:state" args:arguments error:&error];
  NSNumber *count = [result.value objectForKey:@"count"];
  printf("%lld\n", [count longLongValue]); // The value is decoded at runtime.

  [client release]; // This build uses manual reference counting.
  [pool drain];
  return 0;
}
```

The brackets send the `query:args:error:` message to `client`; named pieces such as `args:` are part of the method selector. Unlike `useQuery`, this call is a one-off HTTP query. It returns ordinary Foundation objects rather than a generated TypeScript type, so the complete example validates the dictionary and number before trusting them.

### The caller owns the Live subscription

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function LiveCounter() {
  const room = "readme-objective-c-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={() =>
        increment({ room, language: "TypeScript", runId: crypto.randomUUID() })
      }
    >
      Count: {state?.count ?? "Loading..."}
    </button>
  );
}
```

**Objective-C**

```objective-c
#import "ConvexClient.h"
#import <Foundation/Foundation.h>

static void incrementAndReadUpdate(CVXClient *client) {
  NSString *room = @"readme-objective-c-live";
  NSError *error = nil;
  NSDictionary *queryArguments = @{ @"room" : room };

  // Subscribe first so the mutation's reactive update cannot be missed.
  CVXSubscription *subscription = [client subscribe:@"demo:state"
                                                args:queryArguments
                                               error:&error];
  CVXLiveUpdate *initial =
      [subscription nextUpdateWithTimeoutMilliseconds:10000 error:&error];

  NSDictionary *mutationArguments = @{
    @"room" : room,
    @"language" : @"Objective-C",
    @"runId" : [[NSUUID UUID] UUIDString],
  };
  // A fresh UUID gives this call its own mutation identity.
  CVXResult *mutation = [client mutation:@"demo:increment"
                                    args:mutationArguments
                                   error:&error];
  // Block until Live delivers the state produced by that mutation.
  CVXLiveUpdate *updated =
      [subscription nextUpdateWithTimeoutMilliseconds:10000 error:&error];
  // Decode initial.value, mutation.value, and updated.value as Foundation objects.
  (void)initial;
  (void)mutation;
  (void)updated;
  [subscription unsubscribe:&error]; // The command-line caller cleans up.
}
```

React starts, updates, and disposes the `useQuery` subscription with the component lifecycle. Here the caller creates and removes `CVXSubscription` explicitly. Objective-C can use callbacks and asynchronous APIs, but this client deliberately offers blocking `nextUpdateWithTimeoutMilliseconds:error:` so command-line sequencing stays easy to see. The full example checks every returned value and error.

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
