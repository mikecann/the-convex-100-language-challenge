#ifndef CONVEX_CLIENT_INTERNAL_H
#define CONVEX_CLIENT_INTERNAL_H

#include <json-c/json.h>
#include <stddef.h>

// The adapter and deterministic fixtures use this private C boundary to inspect
// protocol events. Application code only sees the Foundation API in
// ConvexClient.h; CVXClient and CVXSubscription own these handles.
typedef struct convex_client convex_client;
typedef struct convex_subscription convex_subscription;
typedef struct {
  json_object *value;
  json_object *logs;
} convex_result;
typedef struct {
  char *name;
  char *message;
  json_object *data;
  json_object *logs;
} convex_error;
typedef struct {
  json_object *value;
  json_object *logs;
  convex_error error;
} convex_update;

convex_client *convex_new(const char *deployment_url,
                          const char *client_version, convex_error *error);
void convex_free(convex_client *client);
int convex_set_auth(convex_client *client, const char *token,
                    convex_error *error);
int convex_call(convex_client *client, const char *operation, const char *path,
                json_object *args, convex_result *result, convex_error *error);
convex_subscription *convex_subscribe(convex_client *client, const char *path,
                                      json_object *args, convex_error *error);
int convex_subscription_next(convex_subscription *subscription,
                             convex_update *update, int timeout_ms);
int convex_unsubscribe(convex_subscription *subscription, convex_error *error);
int convex_debug_disconnect(convex_client *client, convex_error *error);
int convex_close(convex_client *client, int timeout_ms, convex_error *error);
void convex_update_free(convex_update *update);
void convex_result_free(convex_result *result);
void convex_error_free(convex_error *error);

#endif
