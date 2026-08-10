#define _POSIX_C_SOURCE 200112L
#include <curl/curl.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <netdb.h>
#include <sys/socket.h>

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
                    char *response, size_t capacity, size_t *response_length, long *status) {
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
  *response_length = buffer.length;
  curl_easy_cleanup(curl);
  curl_slist_free_all(headers);
  return result == CURLE_OK;
}

/* TCP mode is an adapter I/O transport only. Once connected, C3 reads and
 * writes the identical NDJSON stream via stdin/stdout. */
int c3_adapter_listen(const char *address) {
  const char *colon = strrchr(address, ':');
  if (!colon || colon == address || !colon[1]) return 0;
  char host[256], port[16];
  size_t host_len = (size_t)(colon - address);
  if (host_len >= sizeof host || strlen(colon + 1) >= sizeof port) return 0;
  memcpy(host, address, host_len); host[host_len] = '\0';
  strcpy(port, colon + 1);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
  if (getaddrinfo(host, port, &hints, &addresses)) return 0;
  int listener = -1;
  for (struct addrinfo *candidate = addresses; candidate; candidate = candidate->ai_next) {
    listener = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
    if (listener < 0) continue;
    int yes = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    if (!bind(listener, candidate->ai_addr, candidate->ai_addrlen) && !listen(listener, 1)) break;
    close(listener); listener = -1;
  }
  freeaddrinfo(addresses);
  if (listener < 0) return 0;
  int peer = accept(listener, NULL, NULL); close(listener);
  if (peer < 0) return 0;
  int ok = dup2(peer, STDIN_FILENO) >= 0 && dup2(peer, STDOUT_FILENO) >= 0;
  close(peer);
  return ok;
}
