#define _POSIX_C_SOURCE 200112L
#include <curl/curl.h>
#include <openssl/evp.h>

#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <netdb.h>
#include <sys/random.h>
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

/* libcurl owns the verified TLS stream. This transport shim adds only the
 * RFC6455 upgrade and frames. It knows nothing about Convex messages,
 * subscriptions, query sets, or reconnects. */
struct c3_websocket {
  CURL *curl;
  curl_socket_t socket;
  int active;
};

/* The shared protocol limits inbound frames to 2 MiB. Enforcing the same
 * ceiling here bounds both the masking allocation and message assembly. */
#define C3_WS_MAX_MESSAGE_BYTES (2U * 1024U * 1024U)

static int64_t monotonic_millis(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int wait_for_socket(struct c3_websocket *websocket, short events,
                           int64_t deadline) {
  for (;;) {
    int64_t remaining = deadline - monotonic_millis();
    if (remaining <= 0) return 0;
    struct pollfd descriptor = {websocket->socket, events, 0};
    int result = poll(&descriptor, 1, remaining > INT32_MAX ? INT32_MAX : (int)remaining);
    if (result > 0)
      return !(descriptor.revents & (POLLERR | POLLHUP | POLLNVAL));
    if (!result) return 0;
    if (errno != EINTR) return 0;
  }
}

static void retire_websocket(struct c3_websocket *websocket) {
  if (!websocket || !websocket->active) return;
  websocket->active = 0;
  curl_easy_cleanup(websocket->curl);
  websocket->curl = NULL;
  websocket->socket = CURL_SOCKET_BAD;
}

static int random_bytes(unsigned char *output, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t received = getrandom(output + offset, length - offset, 0);
    if (received > 0) {
      offset += (size_t)received;
    } else if (errno != EINTR) {
      return 0;
    }
  }
  return 1;
}

int c3_random_session_id(char *output, size_t capacity) {
  unsigned char raw[16];
  if (!output || capacity < 37 || !random_bytes(raw, sizeof raw)) return 0;
  raw[6] = (raw[6] & 0x0f) | 0x40;
  raw[8] = (raw[8] & 0x3f) | 0x80;
  return snprintf(output, capacity,
      "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
      raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]) == 36;
}

long long c3_monotonic_millis(void) {
  return monotonic_millis();
}

static int send_raw(struct c3_websocket *websocket, const void *data, size_t length,
                    int64_t deadline) {
  const unsigned char *bytes = data;
  size_t offset = 0;
  while (offset < length) {
    size_t sent = 0;
    CURLcode result = curl_easy_send(websocket->curl, bytes + offset, length - offset, &sent);
    offset += sent;
    if (result != CURLE_OK && result != CURLE_AGAIN) return 0;
    if (offset == length) return 1;
    if (!wait_for_socket(websocket, POLLOUT, deadline)) return 0;
  }
  return 1;
}

/* Returns 1 when complete, 0 on timeout, and -1 on transport failure. */
static int receive_raw(struct c3_websocket *websocket, void *output, size_t length,
                       size_t *consumed, int64_t deadline) {
  unsigned char *bytes = output;
  while (*consumed < length) {
    size_t received = 0;
    CURLcode result = curl_easy_recv(websocket->curl, bytes + *consumed,
                                     length - *consumed, &received);
    *consumed += received;
    if (result != CURLE_OK && result != CURLE_AGAIN) return -1;
    if (*consumed == length) return 1;
    if (!wait_for_socket(websocket, POLLIN, deadline)) return 0;
  }
  return 1;
}

static int websocket_accept(const char *key, char output[29]) {
  char source[128];
  int source_length = snprintf(source, sizeof source,
      "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key);
  if (source_length <= 0 || source_length >= (int)sizeof source) return 0;
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int digest_length = 0;
  EVP_MD_CTX *context = EVP_MD_CTX_new();
  if (!context) return 0;
  int ok = EVP_DigestInit_ex(context, EVP_sha1(), NULL) == 1 &&
           EVP_DigestUpdate(context, source, (size_t)source_length) == 1 &&
           EVP_DigestFinal_ex(context, digest, &digest_length) == 1;
  EVP_MD_CTX_free(context);
  if (!ok || digest_length != 20) return 0;
  return EVP_EncodeBlock((unsigned char *)output, digest, (int)digest_length) == 28;
}

static int response_has_header(const char *response, const char *name, const char *value,
                               int case_sensitive_value) {
  size_t name_length = strlen(name), value_length = strlen(value);
  const char *line = strstr(response, "\r\n") + 2;
  while (line && *line && strncmp(line, "\r\n", 2)) {
    const char *end = strstr(line, "\r\n");
    if (!end) return 0;
    const char *colon = memchr(line, ':', (size_t)(end - line));
    if (colon && (size_t)(colon - line) == name_length &&
        !strncasecmp(line, name, name_length)) {
      const char *start = colon + 1;
      while (start < end && (*start == ' ' || *start == '\t')) start++;
      const char *finish = end;
      while (finish > start && (finish[-1] == ' ' || finish[-1] == '\t')) finish--;
      return (size_t)(finish - start) == value_length &&
             (case_sensitive_value ? !memcmp(start, value, value_length)
                                   : !strncasecmp(start, value, value_length));
    }
    line = end + 2;
  }
  return 0;
}

static int perform_websocket_upgrade(struct c3_websocket *websocket, const char *url,
                                     long timeout_millis) {
  const char *scheme_end = strstr(url, "://");
  if (!scheme_end) return 0;
  const char *authority = scheme_end + 3;
  const char *path = strchr(authority, '/');
  size_t authority_length = path ? (size_t)(path - authority) : strlen(authority);
  if (!authority_length || authority_length > 511 || strpbrk(authority, "\r\n#")) return 0;
  if (!path) path = "/";

  unsigned char nonce[16];
  char key[25] = {0}, expected_accept[29] = {0};
  if (!random_bytes(nonce, sizeof nonce) ||
      EVP_EncodeBlock((unsigned char *)key, nonce, sizeof nonce) != 24 ||
      !websocket_accept(key, expected_accept)) return 0;
  char request[2048];
  int request_length = snprintf(request, sizeof request,
      "GET %s HTTP/1.1\r\nHost: %.*s\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
      "Sec-WebSocket-Key: %s\r\n\r\n",
      path, (int)authority_length, authority, key);
  if (request_length <= 0 || request_length >= (int)sizeof request) return 0;
  int64_t deadline = monotonic_millis() + timeout_millis;
  if (!send_raw(websocket, request, (size_t)request_length, deadline)) return 0;

  char response[8192] = {0};
  size_t length = 0;
  while (length < sizeof response - 1 && !strstr(response, "\r\n\r\n")) {
    size_t one = 0;
    int result = receive_raw(websocket, response + length, 1, &one, deadline);
    if (result != 1) return 0;
    length++;
    response[length] = '\0';
  }
  return strstr(response, "\r\n\r\n") && !strncmp(response, "HTTP/1.1 101 ", 13) &&
         response_has_header(response, "Upgrade", "websocket", 0) &&
         response_has_header(response, "Connection", "Upgrade", 0) &&
         response_has_header(response, "Sec-WebSocket-Accept", expected_accept, 1);
}

void *c3_ws_connect(const char *url, const char *ca_path, long timeout_millis) {
  if (!url || timeout_millis <= 0) return NULL;
  int secure = !strncmp(url, "wss://", 6);
  int plaintext = !strncmp(url, "ws://", 5);
  if (!secure && !plaintext) return NULL;
  const char *remainder = url + (secure ? 6 : 5);
  char connection_url[2048];
  if (snprintf(connection_url, sizeof connection_url, "%s://%s",
               secure ? "https" : "http", remainder) >= (int)sizeof connection_url)
    return NULL;
  CURL *curl = curl_easy_init();
  if (!curl) return NULL;
  curl_easy_setopt(curl, CURLOPT_URL, connection_url);
  curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 1L);
  curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, timeout_millis);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, timeout_millis);
  if (secure) {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CAINFO,
                     ca_path && *ca_path ? ca_path : "/etc/ssl/certs/ca-certificates.crt");
  }
  curl_easy_setopt(curl, CURLOPT_NOPROXY, "*");
  if (curl_easy_perform(curl) != CURLE_OK) {
    curl_easy_cleanup(curl);
    return NULL;
  }
  curl_socket_t socket = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(curl, CURLINFO_ACTIVESOCKET, &socket) != CURLE_OK ||
      socket == CURL_SOCKET_BAD) {
    curl_easy_cleanup(curl);
    return NULL;
  }
  struct c3_websocket *websocket = calloc(1, sizeof *websocket);
  if (!websocket) {
    curl_easy_cleanup(curl);
    return NULL;
  }
  websocket->curl = curl;
  websocket->socket = socket;
  websocket->active = 1;
  if (!perform_websocket_upgrade(websocket, url, timeout_millis)) {
    retire_websocket(websocket);
    free(websocket);
    return NULL;
  }
  return websocket;
}

int c3_ws_is_active(void *opaque) {
  struct c3_websocket *websocket = opaque;
  return websocket && websocket->active;
}

static int send_frame(struct c3_websocket *websocket, unsigned char opcode,
                      const void *data, size_t length, long timeout_millis) {
  if (!websocket || !websocket->active || timeout_millis <= 0 ||
      ((opcode & 8) && length > 125) || length > C3_WS_MAX_MESSAGE_BYTES) return 0;
  unsigned char header[14], mask[4];
  size_t header_length = 0;
  header[header_length++] = 0x80 | opcode;
  if (length < 126) {
    header[header_length++] = 0x80 | (unsigned char)length;
  } else if (length <= UINT16_MAX) {
    header[header_length++] = 0x80 | 126;
    header[header_length++] = (unsigned char)(length >> 8);
    header[header_length++] = (unsigned char)length;
  } else {
    header[header_length++] = 0x80 | 127;
    uint64_t wide_length = length;
    for (int shift = 56; shift >= 0; shift -= 8)
      header[header_length++] = (unsigned char)(wide_length >> shift);
  }
  if (!random_bytes(mask, sizeof mask)) return 0;
  memcpy(header + header_length, mask, sizeof mask);
  header_length += sizeof mask;
  unsigned char *masked = malloc(length ? length : 1);
  if (!masked) return 0;
  for (size_t index = 0; index < length; index++)
    masked[index] = ((const unsigned char *)data)[index] ^ mask[index % 4];
  int64_t deadline = monotonic_millis() + timeout_millis;
  int ok = send_raw(websocket, header, header_length, deadline) &&
           send_raw(websocket, masked, length, deadline);
  free(masked);
  if (!ok) retire_websocket(websocket);
  return ok;
}

int c3_ws_send_text(void *opaque, const char *data, size_t length, long timeout_millis) {
  if (!data && length) return 0;
  return send_frame(opaque, 1, data ? data : "", length, timeout_millis);
}

static int valid_utf8(const unsigned char *bytes, size_t length) {
  for (size_t index = 0; index < length;) {
    unsigned char first = bytes[index++];
    if (first < 0x80) continue;
    size_t continuation = first >= 0xc2 && first <= 0xdf ? 1
                        : first >= 0xe0 && first <= 0xef ? 2
                        : first >= 0xf0 && first <= 0xf4 ? 3 : 99;
    if (continuation == 99 || continuation > length - index) return 0;
    if (continuation == 2 && ((first == 0xe0 && bytes[index] < 0xa0) ||
                              (first == 0xed && bytes[index] >= 0xa0))) return 0;
    if (continuation == 3 && ((first == 0xf0 && bytes[index] < 0x90) ||
                              (first == 0xf4 && bytes[index] >= 0x90))) return 0;
    for (size_t count = 0; count < continuation; count++)
      if ((bytes[index++] & 0xc0) != 0x80) return 0;
  }
  return 1;
}

/* Return 1 for a complete text message, 0 for an idle timeout, 2 for peer
 * close, and -1 for a retired/invalid connection. A timeout after consuming
 * any frame byte retires the connection rather than guessing a new boundary. */
int c3_ws_receive_text(void *opaque, char *output, size_t capacity, size_t *length,
                       long timeout_millis) {
  struct c3_websocket *websocket = opaque;
  if (!websocket || !websocket->active || !output || !capacity || !length ||
      timeout_millis <= 0) return -1;
  *length = 0;
  int fragmented = 0;
  int frame_started = 0;
  int64_t deadline = monotonic_millis() + timeout_millis;
  for (;;) {
    unsigned char header[2];
    size_t consumed = 0;
    int result = receive_raw(websocket, header, sizeof header, &consumed, deadline);
    frame_started |= consumed != 0;
    if (result == 0 && !frame_started) return 0;
    if (result != 1) break;
    frame_started = 1;
    int final = !!(header[0] & 0x80);
    unsigned char opcode = header[0] & 0x0f;
    if ((header[0] & 0x70) || (header[1] & 0x80)) break;
    uint64_t payload_length = header[1] & 0x7f;
    if (payload_length == 126 || payload_length == 127) {
      size_t extended_length = payload_length == 126 ? 2 : 8;
      unsigned char extended[8];
      consumed = 0;
      if (receive_raw(websocket, extended, extended_length, &consumed, deadline) != 1) break;
      payload_length = 0;
      for (size_t index = 0; index < extended_length; index++)
        payload_length = (payload_length << 8) | extended[index];
      if ((extended_length == 2 && payload_length < 126) ||
          (extended_length == 8 && (payload_length <= UINT16_MAX || (extended[0] & 0x80)))) break;
    }
    int control = opcode & 8;
    if ((control && (!final || payload_length > 125)) || payload_length > SIZE_MAX) break;
    unsigned char control_payload[125];
    unsigned char *destination = control ? control_payload : (unsigned char *)output + *length;
    if (!control && (payload_length > capacity - *length ||
                     payload_length > C3_WS_MAX_MESSAGE_BYTES - *length)) break;
    consumed = 0;
    if (receive_raw(websocket, destination, (size_t)payload_length, &consumed, deadline) != 1)
      break;
    if (opcode == 8) {
      retire_websocket(websocket);
      return 2;
    }
    if (opcode == 9) {
      if (!send_frame(websocket, 10, control_payload, (size_t)payload_length,
                      timeout_millis)) return -1;
      continue;
    }
    if (opcode == 10) continue;
    if ((opcode == 1 && fragmented) || (opcode == 0 && !fragmented) ||
        (opcode != 0 && opcode != 1)) break;
    *length += (size_t)payload_length;
    if (!final) {
      fragmented = 1;
      continue;
    }
    if (!valid_utf8((unsigned char *)output, *length)) break;
    return 1;
  }
  retire_websocket(websocket);
  return -1;
}

int c3_ws_close(void *opaque, long timeout_millis) {
  struct c3_websocket *websocket = opaque;
  if (!websocket || !websocket->active) return 1;
  unsigned char normal_close[2] = {0x03, 0xe8};
  int sent = send_frame(websocket, 8, normal_close, sizeof normal_close, timeout_millis);
  retire_websocket(websocket);
  return sent;
}

void c3_ws_free(void *opaque) {
  struct c3_websocket *websocket = opaque;
  if (!websocket) return;
  retire_websocket(websocket);
  free(websocket);
}

/* Adapter multiplexing remains C3-owned. This exposes only POSIX readiness so
 * the owner can service WebSocket messages while waiting for NDJSON input. */
int c3_stdin_ready(long timeout_millis) {
  if (timeout_millis < 0 || timeout_millis > INT32_MAX) return 0;
  struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
  int result;
  do {
    result = poll(&descriptor, 1, (int)timeout_millis);
  } while (result < 0 && errno == EINTR);
  return result > 0 && (descriptor.revents & (POLLIN | POLLHUP));
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
