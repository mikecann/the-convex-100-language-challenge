# Convex from C

A compact native C client that calls Convex functions over HTTP and keeps queries current over the pinned Live WebSocket profile.

This is educational and unofficial, not a production Convex SDK.

## Start here

[`examples/basics/main.c`](examples/basics/main.c) follows the shared counter from 0 to 1 using an HTTP query, a Live subscription started before the mutation, and an idempotent mutation.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |

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

## Docker verification

`./run test c` compiles the client and its adapter in Docker. `./run verify-example c` exercises the exact example against the dedicated backend. `./run verify c` is the shared HTTP and Live conformance gate.

## Protocol notes and limits

The adapter speaks NDJSON protocol v1 on stdin/stdout or one `ADAPTER_LISTEN` TCP connection. libcurl supplies ordinary HTTP, TLS, and WebSocket transport and json-c supplies JSON parsing; Convex behavior and sync state are implemented here in C. One worker owns the WebSocket, reconnects with 100 ms to 15 s exponential backoff, and resubscribes with fresh Add messages. Subscription queues retain the newest 16 updates. Live authentication, optimistic updates, tagged values, cancellation, streaming HTTP responses, and `TransitionChunk` assembly are deferred.
