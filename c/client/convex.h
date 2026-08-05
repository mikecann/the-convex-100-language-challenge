#ifndef CONVEX_H
#define CONVEX_H

#include <json-c/json.h>

/* A deliberately small, native C wrapper around Convex's documented HTTP API. */
typedef struct convex_client convex_client;
typedef struct { json_object *value; json_object *logs; } convex_result;
typedef struct { char *name; char *message; json_object *data; json_object *logs; } convex_error;

convex_client *convex_new(const char *deployment_url, const char *client_version, convex_error *error);
void convex_free(convex_client *client);
int convex_set_auth(convex_client *client, const char *token, convex_error *error);
int convex_call(convex_client *client, const char *operation, const char *path,
                json_object *args, convex_result *result, convex_error *error);
void convex_result_free(convex_result *result);
void convex_error_free(convex_error *error);
#endif
