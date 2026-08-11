#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_MESSAGES 128
#define MAX_MESSAGE_BYTES 16384

struct fixture_socket { int active; };
static char sent[MAX_MESSAGES][MAX_MESSAGE_BYTES];
static char incoming[MAX_MESSAGES][MAX_MESSAGE_BYTES];
static size_t sent_count, incoming_head, incoming_count;
static int connect_count;
static long long now_millis;

void fixture_reset(void) {
  memset(sent, 0, sizeof sent);
  memset(incoming, 0, sizeof incoming);
  sent_count = incoming_head = incoming_count = 0;
  connect_count = 0;
  now_millis = 0;
}

int fixture_push(const char *message) {
  if (incoming_count >= MAX_MESSAGES || strlen(message) >= MAX_MESSAGE_BYTES) return 0;
  strcpy(incoming[incoming_count++], message);
  return 1;
}

int fixture_sent_contains(const char *fragment) {
  for (size_t index = 0; index < sent_count; index++)
    if (strstr(sent[index], fragment)) return 1;
  return 0;
}

int fixture_connect_count(void) { return connect_count; }
void fixture_advance(long long millis) { now_millis += millis; }

void *c3_ws_connect(const char *url, const char *ca_path, long timeout_millis) {
  (void)ca_path;
  if (!url || strncmp(url, "wss://", 6) || timeout_millis <= 0) return NULL;
  struct fixture_socket *socket = calloc(1, sizeof *socket);
  if (!socket) return NULL;
  socket->active = 1;
  connect_count++;
  return socket;
}

int c3_ws_is_active(void *opaque) {
  struct fixture_socket *socket = opaque;
  return socket && socket->active;
}

int c3_ws_send_text(void *opaque, const char *data, size_t length, long timeout_millis) {
  struct fixture_socket *socket = opaque;
  if (!socket || !socket->active || timeout_millis <= 0 ||
      sent_count >= MAX_MESSAGES || length >= MAX_MESSAGE_BYTES) return 0;
  memcpy(sent[sent_count], data, length);
  sent[sent_count][length] = '\0';
  sent_count++;
  return 1;
}

int c3_ws_receive_text(void *opaque, char *output, size_t capacity,
                       size_t *length, long timeout_millis) {
  struct fixture_socket *socket = opaque;
  (void)timeout_millis;
  if (!socket || !socket->active) return -1;
  if (incoming_head >= incoming_count) return 0;
  size_t bytes = strlen(incoming[incoming_head]);
  if (bytes > capacity) return -1;
  memcpy(output, incoming[incoming_head++], bytes);
  *length = bytes;
  return 1;
}

int c3_ws_close(void *opaque, long timeout_millis) {
  struct fixture_socket *socket = opaque;
  (void)timeout_millis;
  if (socket) socket->active = 0;
  return 1;
}

void c3_ws_free(void *opaque) { free(opaque); }

int c3_random_session_id(char *output, size_t capacity) {
  if (capacity < 37) return 0;
  snprintf(output, capacity, "00000000-0000-4000-8000-%012d", connect_count);
  return 1;
}

long long c3_monotonic_millis(void) { return now_millis; }
