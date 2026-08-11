#include <stdio.h>
#include <string.h>

/* This is a transport fixture, not a Convex client. It records the completed
 * C3 request and supplies HTTP-shaped byte streams so C3 owns routing and all
 * response classification without an external deployment. */
int c3_http_request(const char *method, const char *url, const char *body,
                    const char *bearer, char *response, size_t capacity,
                    size_t *response_length, long *status) {
  const char *reply = "{\"status\":\"success\",\"value\":{\"count\":1.0},\"logLines\":[]}";
  if (strstr(url, "/api/action"))
    reply = "{\"status\":\"error\",\"errorMessage\":\"fixture action failure\",\"errorData\":{\"code\":\"ACTION\"},\"logLines\":[\"fixture\"]}";
  if (strstr(url, "/api/mutation") && (!body || !strstr(body, "idempotencyKey")))
    return 0;
  if (strstr(url, "/api/transport")) {
    *status = 503;
    reply = "upstream unavailable";
  } else {
    *status = 200;
  }
  if (strcmp(method, "POST") != 0 || (bearer && strcmp(bearer, "token") != 0 && *bearer))
    return 0;
  if (snprintf(response, capacity, "%s", reply) >= (int)capacity)
    return 0;
  *response_length = strlen(reply);
  return 1;
}
