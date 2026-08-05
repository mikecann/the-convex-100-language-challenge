#ifndef CONVEX_H
#define CONVEX_H

#include <json-c/json.h>
#include <stddef.h>

/* A deliberately small, native C wrapper around Convex's documented HTTP API. */
typedef struct convex_client convex_client;
typedef struct convex_subscription convex_subscription;
typedef struct { json_object *value; json_object *logs; } convex_result;
typedef struct { char *name; char *message; json_object *data; json_object *logs; } convex_error;
typedef struct { json_object *value; json_object *logs; convex_error error; } convex_update;

convex_client *convex_new(const char *deployment_url, const char *client_version, convex_error *error);
void convex_free(convex_client *client);
int convex_set_auth(convex_client *client, const char *token, convex_error *error);
int convex_call(convex_client *client, const char *operation, const char *path,
                json_object *args, convex_result *result, convex_error *error);
/* Live subscriptions run on one client-owned worker. The worker is the only
 * thread that touches libcurl's WebSocket handle. */
convex_subscription *convex_subscribe(convex_client *client, const char *path,
                                      json_object *args, convex_error *error);
/* Returns 1 for an update, 0 for timeout, and -1 after close. */
int convex_subscription_next(convex_subscription *subscription, convex_update *update,
                             int timeout_ms);
int convex_unsubscribe(convex_subscription *subscription, convex_error *error);
int convex_debug_disconnect(convex_client *client, convex_error *error);
int convex_close(convex_client *client, int timeout_ms, convex_error *error);
void convex_update_free(convex_update *update);
void convex_result_free(convex_result *result);
void convex_error_free(convex_error *error);
#endif
