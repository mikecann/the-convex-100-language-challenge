<img src="logo.png" alt="C logo" width="128">
<!-- Logo source: https://www.c-language.org/logo.svg -->

# C

C is a general-purpose language created by Dennis Ritchie at Bell Labs in the early 1970s alongside Unix. It grew from B and BCPL, then influenced the syntax and systems-programming style of languages including C++, Java, C#, and JavaScript. C is still a practical lingua franca for operating systems, embedded software, language runtimes, and portable native libraries. The [C Standards Committee's website](https://www.c-language.org/) is a good starting point, and Ritchie's [history of C](https://www.bell-labs.com/usr/dmr/www/chist.pdf) tells the origin story in his own words. The current language standard is [C23, published as ISO/IEC 9899:2024](https://www.iso.org/standard/82075.html).

This repository contains an educational, unofficial client demonstration. It is not a production Convex SDK.

## Getting Started

The canonical [`examples/basics/main.c`](examples/basics/main.c) program reads a counter, subscribes before changing it, applies one idempotent mutation, and observes the resulting Live update.

From the repository root, run the exact example in its Docker image against the project's dedicated test backend:

```sh
./run verify-example c
```

## Interesting Parts

### A reactive query becomes an explicit subscription handle

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CurrentCount() {
  const room = "readme-c";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // React rerenders when this query changes.
}
```

**C**

```c
#include "convex.h"
#include <curl/curl.h>
#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  curl_global_init(CURL_GLOBAL_DEFAULT);
  convex_error error = {0};
  const char *deployment_url = getenv("CONVEX_URL");
  convex_client *client = convex_new(deployment_url, "c-readme", &error);
  if (!client)
    return 1;

  /* json-c builds the { room: "readme-c" } argument object explicitly. */
  json_object *args = json_object_new_object();
  json_object_object_add(args, "room", json_object_new_string("readme-c"));

  convex_subscription *subscription =
      convex_subscribe(client, "demo:state", args, &error);
  convex_update update = {0};
  if (!subscription ||
      convex_subscription_next(subscription, &update, 10000) != 1)
    return 1;

  json_object *count = NULL;
  json_object_object_get_ex(update.value, "count", &count);
  printf("%d\n", json_object_get_int(count)); /* The initial Live value. */

  convex_update_free(&update); /* Release the value returned by next(). */
  convex_unsubscribe(subscription, &error);
  json_object_put(args); /* Release the argument tree owned by this scope. */
  convex_free(client);   /* Stops the worker and releases the client. */
  return 0;
}
```

`useQuery` owns the subscription lifecycle and causes React to rerender. This C client instead returns a subscription handle and exposes a blocking `convex_subscription_next` operation. That blocking API is a deliberate client design for a small command-line demonstration, not a limitation of C or pthreads. See the complete [counter sequence](examples/basics/main.c).

### Function arguments and results are reference-counted JSON trees

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const room = "readme-c";
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={async () => {
        const result = await increment({
          room,
          language: "TypeScript",
          runId: crypto.randomUUID(),
        });
        console.log(result.state.count); // The generated API types this result.
      }}
    >
      Increment
    </button>
  );
}
```

**C**

```c
#include "convex.h"
#include <curl/curl.h>
#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  curl_global_init(CURL_GLOBAL_DEFAULT);
  convex_error error = {0};
  convex_result result = {0};
  const char *deployment_url = getenv("CONVEX_URL");
  convex_client *client = convex_new(deployment_url, "c-readme", &error);
  if (!client)
    return 1;

  /* Construct the three arguments accepted by the demo:increment mutation. */
  json_object *args = json_object_new_object();
  json_object_object_add(args, "room", json_object_new_string("readme-c"));
  json_object_object_add(args, "language", json_object_new_string("C"));
  json_object_object_add(args, "runId",
                         json_object_new_string("readme-c-once"));

  if (!convex_call(client, "mutation", "demo:increment", args, &result,
                   &error))
    return 1;

  json_object *state = NULL;
  json_object *count = NULL;
  json_object_object_get_ex(result.value, "state", &state);
  json_object_object_get_ex(state, "count", &count);
  printf("%d\n", json_object_get_int(count)); /* Decode the returned state. */

  convex_result_free(&result); /* Release the client's result references. */
  json_object_put(args);       /* Release args and all of its child values. */
  convex_free(client);
  return 0;
}
```

The React client gets generated argument and return types. C has no generated bindings here, so the function path is a string and json-c represents both inputs and outputs. The fixed `runId` makes this focused C mutation idempotent: retrying it does not increment twice.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.c -->
```c
#include "convex.h"
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>

/* Convex's JSON encoding can represent a whole count as 0 or 0.0. This check
 * accepts both without accidentally truncating a fractional value. */
static int whole(json_object *value) {
  return json_object_get_type(value) == json_type_int ||
         (json_object_get_type(value) == json_type_double &&
          json_object_get_double(value) ==
              (double)json_object_get_int64(value));
}

static int count_of(json_object *value) {
  json_object *count = NULL;
  return json_object_object_get_ex(value, "count", &count) && whole(count)
             ? json_object_get_int(count)
             : -1;
}

static void die(convex_client *client, convex_error *error,
                const char *fallback) {
  fprintf(stderr, "%s\n", error->message ? error->message : fallback);
  convex_error_free(error);
  convex_free(client);
  exit(1);
}

int main(int argc, char **argv) {
  const char *url = getenv("CONVEX_URL");
  const char *room = argc > 1 ? argv[1] : "c-basic-example";
  convex_error error = {0};
  convex_result result = {0};
  curl_global_init(CURL_GLOBAL_DEFAULT);

  /* Configure the deployment from the environment and create the client. */
  convex_client *client = convex_new(url, "c-0.1.0", &error);
  if (!client)
    die(client, &error, "could not create client");

  /* Query the current counter over HTTP and decode its JSON object. */
  json_object *query_args = json_object_new_object();
  json_object_object_add(query_args, "room", json_object_new_string(room));
  if (!convex_call(client, "query", "demo:state", query_args, &result,
                   &error) ||
      count_of(result.value) != 0)
    die(client, &error, "unexpected initial query value");
  printf("current count: 0\n");
  convex_result_free(&result);

  /* Start Live before the mutation so no reactive update can be missed. */
  convex_subscription *subscription =
      convex_subscribe(client, "demo:state", query_args, &error);
  convex_update update = {0};
  if (!subscription)
    die(client, &error, "could not subscribe");
  if (convex_subscription_next(subscription, &update, 10000) != 1 ||
      update.error.name || count_of(update.value) != 0)
    die(client, &update.error, "unexpected initial Live value");
  printf("live initial count: 0\n");
  convex_update_free(&update);

  /* The run ID makes the mutation safe to retry without incrementing twice. */
  json_object *mutation_args = json_object_new_object();
  json_object_object_add(mutation_args, "room", json_object_new_string(room));
  json_object_object_add(mutation_args, "language",
                         json_object_new_string("C"));
  char run_id[1024];
  snprintf(run_id, sizeof(run_id), "%s-once", room);
  json_object_object_add(mutation_args, "runId",
                         json_object_new_string(run_id));
  if (!convex_call(client, "mutation", "demo:increment", mutation_args, &result,
                   &error))
    die(client, &error, "mutation failed");
  json_object *applied = NULL, *state = NULL;
  if (!json_object_object_get_ex(result.value, "applied", &applied) ||
      !json_object_get_boolean(applied) ||
      !json_object_object_get_ex(result.value, "state", &state) ||
      count_of(state) != 1)
    die(client, &error, "unexpected mutation result");
  printf("mutation applied: true\nmutation count: 1\n");
  convex_result_free(&result);

  /* Decode the resulting Live update, then cleanly remove the subscription. */
  if (convex_subscription_next(subscription, &update, 10000) != 1 ||
      update.error.name || count_of(update.value) != 1)
    die(client, &update.error, "unexpected updated Live value");
  printf("live updated count: 1\n");
  convex_update_free(&update);
  if (!convex_unsubscribe(subscription, &error))
    die(client, &error, "unsubscribe failed");

  /* Print verification only after HTTP and Live agree on the 0 -> 1 journey. */
  printf("verified count: 0 -> 1\n");
  json_object_put(query_args);
  json_object_put(mutation_args);
  convex_free(client);
  return 0;
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native C17 implementation. [libcurl](https://curl.se/libcurl/c/libcurl-ws.html) supplies HTTP, TLS, and WebSocket transport, while [json-c](https://json-c.github.io/json-c/json-c-current-release/doc/html/index.html) supplies the reference-counted JSON object model. Convex request construction, response decoding, Live query state, reconnection, and error classification are implemented in [`client/convex.c`](client/convex.c), rather than delegated to another Convex client.

One pthread worker exclusively owns the WebSocket. Application code adds or removes subscriptions and waits on per-subscription queues, so it never reads or writes the socket concurrently. Each queue retains the newest 16 updates and drops the oldest when its consumer falls behind. The worker reconnects with exponential backoff from 100 milliseconds up to 15 seconds, resends active subscriptions, and suppresses an unchanged rehydration value.

The canonical source is compiled with GCC 14.2.0 in Docker using `-std=c17`. The final images contain the compiled program, runtime libraries, CA certificates, and a deliberately restricted shell surface, but no compiler or package manager.

These repository commands represent different evidence layers:

```sh
./run test c             # Formatting, compilation, and language-local tests.
./run verify-example c   # The exact canonical example against a unique room.
./run verify c           # Example plus shared local HTTP and Live conformance.
./run verify-hosted c    # The same checks against the hosted drift target.
./run verify-all c       # Both deployment profiles from the same source.
```

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations, and WebSocket actions are deferred. HTTP bearer-token replacement is supported.
2. Live values cover the JSON-safe subset. Tagged Convex values are not decoded yet.
3. `TransitionChunk` assembly is not implemented. Receiving one is treated as protocol drift and triggers reconnection.
4. A slow Live consumer can lose intermediate values because the fixed 16-entry queue keeps the newest updates.
