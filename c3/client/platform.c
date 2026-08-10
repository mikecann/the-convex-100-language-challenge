#include <curl/curl.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Deliberately transport-only. C3 decides Convex URLs, function paths,
 * request bodies, response interpretation, subscriptions, and reconnects. */
struct c3_response_buffer {
  char *data;
  size_t capacity;
  size_t length;
};

static size_t receive(void *contents, size_t size, size_t count, void *opaque) {
  struct c3_response_buffer *buffer = opaque;
  size_t bytes = size * count;
  if (bytes > buffer->capacity - buffer->length - 1)
    return 0;
  memcpy(buffer->data + buffer->length, contents, bytes);
  buffer->length += bytes;
  buffer->data[buffer->length] = '\0';
  return bytes;
}

int c3_http_request(const char *method, const char *url, const char *body, const char *bearer,
                    char *response, size_t capacity, long *status) {
  CURL *curl = curl_easy_init();
  if (!curl || capacity < 2)
    return 0;
  struct c3_response_buffer buffer = {response, capacity, 0};
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, receive);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buffer);
  curl_easy_setopt(curl, CURLOPT_CAINFO, "/etc/ssl/certs/ca-certificates.crt");
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
  char authorization[4096];
  if (bearer && *bearer) {
    snprintf(authorization, sizeof authorization, "Authorization: Bearer %s", bearer);
    headers = curl_slist_append(headers, authorization);
  }
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  if (body) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
  }
  CURLcode result = curl_easy_perform(curl);
  if (result == CURLE_OK)
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status);
  curl_easy_cleanup(curl);
  curl_slist_free_all(headers);
  return result == CURLE_OK;
}
