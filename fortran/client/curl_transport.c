#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "curl_transport.h"

#include <ares.h>
#include <arpa/inet.h>
#include <curl/curl.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define FT_MAX_MESSAGE (2U * 1024U * 1024U)
#define FT_MAX_HANDSHAKE 16384U
#define FT_CONNECT_TIMEOUT_MS 10000
#define FT_WRITE_TIMEOUT_MS 500

struct bytes {
  unsigned char *data;
  size_t length;
};

struct socket_handle {
  int fd;
  int secure;
  SSL_CTX *context;
  SSL *ssl;
  struct bytes fragmented;
  int fragment_opcode;
};

struct thread_handle {
  pthread_t thread;
};

struct resolver_result {
  struct ares_addrinfo *addresses;
  int status;
  int done;
};

struct stream_handle {
  int input_fd;
  int output_fd;
  int owns_fds;
  pthread_mutex_t output_mutex;
};

static pthread_once_t initialize_once = PTHREAD_ONCE_INIT;
#ifdef FORTRAN_TRANSPORT_TESTING
static volatile sig_atomic_t test_resolver_started;
#endif

static void initialize_libraries(void) {
  signal(SIGPIPE, SIG_IGN);
  curl_global_init(CURL_GLOBAL_DEFAULT);
  ares_library_init(ARES_LIB_INIT_ALL);
  OPENSSL_init_ssl(0, NULL);
}

static char *copy_text(const char *text) {
  size_t length = strlen(text) + 1;
  char *copy = malloc(length);
  if (copy) memcpy(copy, text, length);
  return copy;
}

static void set_error(char **target, const char *message) {
  if (target) *target = copy_text(message ? message : "transport failure");
}

static size_t collect(void *contents, size_t size, size_t count, void *opaque) {
  struct bytes *bytes = opaque;
  if (size && count > SIZE_MAX / size) return 0;
  size_t add = size * count;
  if (bytes->length > FT_MAX_MESSAGE || add > FT_MAX_MESSAGE - bytes->length)
    return 0;
  unsigned char *next = realloc(bytes->data, bytes->length + add + 1);
  if (!next) return 0;
  bytes->data = next;
  memcpy(bytes->data + bytes->length, contents, add);
  bytes->length += add;
  bytes->data[bytes->length] = '\0';
  return add;
}

int ft_http_post(const char *url, const char *payload, const char *token,
                 char **body, size_t *body_length, char **error) {
  pthread_once(&initialize_once, initialize_libraries);
  *body = NULL;
  *body_length = 0;
  *error = NULL;
  CURL *easy = curl_easy_init();
  struct curl_slist *headers = NULL;
  struct bytes response = {0};
  if (!easy) {
    set_error(error, "could not create libcurl HTTP handle");
    return 0;
  }
  headers = curl_slist_append(headers, "Content-Type: application/json");
  headers = curl_slist_append(headers, "Accept: application/json");
  headers = curl_slist_append(headers, "Convex-Client: fortran-0.1.0");
  if (token && *token) {
    size_t length = strlen(token) + sizeof("Authorization: Bearer ");
    char *header = malloc(length);
    if (!header) {
      set_error(error, "out of memory while building authorization header");
      curl_slist_free_all(headers);
      curl_easy_cleanup(easy);
      return 0;
    }
    snprintf(header, length, "Authorization: Bearer %s", token);
    headers = curl_slist_append(headers, header);
    free(header);
  }
  curl_easy_setopt(easy, CURLOPT_URL, url);
  curl_easy_setopt(easy, CURLOPT_POST, 1L);
  curl_easy_setopt(easy, CURLOPT_POSTFIELDS, payload);
  curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, collect);
  curl_easy_setopt(easy, CURLOPT_WRITEDATA, &response);
  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
  curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, 30000L);
  CURLcode result = curl_easy_perform(easy);
  curl_slist_free_all(headers);
  curl_easy_cleanup(easy);
  if (result != CURLE_OK) {
    free(response.data);
    set_error(error, curl_easy_strerror(result));
    return 0;
  }
  *body = (char *)response.data;
  *body_length = response.length;
  return 1;
}

int64_t ft_monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int wait_fd(int fd, short events, int64_t deadline) {
  for (;;) {
    int64_t remaining = deadline - ft_monotonic_ms();
    if (remaining <= 0) return 0;
    if (remaining > 30000) remaining = 30000;
    struct pollfd descriptor = {.fd = fd, .events = events};
    int result = poll(&descriptor, 1, (int)remaining);
    if (result >= 0) return result;
    if (errno != EINTR) return -1;
  }
}

static int set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void resolved(void *opaque, int status, int timeouts,
                     struct ares_addrinfo *addresses) {
  (void)timeouts;
  struct resolver_result *result = opaque;
  result->status = status;
  result->addresses = addresses;
  result->done = 1;
}

static int resolve_bounded(const char *host, const char *port,
                           struct ares_addrinfo **addresses, char **error) {
#ifdef FORTRAN_TRANSPORT_TESTING
  if (!strcmp(host, "fortran-stall.invalid")) {
    /* Model a resolver which never produces a socket. The transport stays in
     * the sole owner thread, so expiry leaves no detached work behind. */
    test_resolver_started = 1;
    int64_t deadline = ft_monotonic_ms() + FT_CONNECT_TIMEOUT_MS;
    while (ft_monotonic_ms() < deadline) {
      struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000L};
      nanosleep(&pause, NULL);
    }
    set_error(error, "DNS resolution timed out");
    return 0;
  }
#endif

  ares_channel channel;
  int status = ares_init(&channel);
  if (status != ARES_SUCCESS) {
    set_error(error, ares_strerror(status));
    return 0;
  }

  struct resolver_result result = {0};
  struct ares_addrinfo_hints hints = {
      .ai_family = AF_UNSPEC,
      .ai_socktype = SOCK_STREAM,
      .ai_protocol = IPPROTO_TCP,
  };
  ares_getaddrinfo(channel, host, port, &hints, resolved, &result);
  int64_t deadline = ft_monotonic_ms() + FT_CONNECT_TIMEOUT_MS;
  while (!result.done) {
    int64_t remaining = deadline - ft_monotonic_ms();
    if (remaining <= 0) break;

    ares_socket_t sockets[ARES_GETSOCK_MAXNUM];
    unsigned int bits =
        (unsigned int)ares_getsock(channel, sockets, ARES_GETSOCK_MAXNUM);
    struct pollfd descriptors[ARES_GETSOCK_MAXNUM];
    int count = 0;
    for (int index = 0; index < ARES_GETSOCK_MAXNUM; index++) {
      short events = 0;
      /* c-ares 1.18.1's writable macro shifts a signed 1 into bit 31 for
       * socket 15. Use the documented bit layout with unsigned masks. */
      if (bits & (1U << index)) events |= POLLIN;
      if (bits & (1U << (index + ARES_GETSOCK_MAXNUM))) events |= POLLOUT;
      if (events) {
        descriptors[count].fd = sockets[index];
        descriptors[count].events = events;
        descriptors[count].revents = 0;
        count++;
      }
    }

    int wait_ms = remaining > 100 ? 100 : (int)remaining;
    int ready = poll(descriptors, (nfds_t)count, wait_ms);
    if (ready < 0 && errno != EINTR) {
      result.status = ARES_ECONNREFUSED;
      break;
    }
    if (ready <= 0) {
      ares_process_fd(channel, ARES_SOCKET_BAD, ARES_SOCKET_BAD);
      continue;
    }
    for (int index = 0; index < count; index++) {
      ares_socket_t read_fd =
          (descriptors[index].revents & (POLLIN | POLLERR | POLLHUP))
              ? descriptors[index].fd
              : ARES_SOCKET_BAD;
      ares_socket_t write_fd = (descriptors[index].revents & POLLOUT)
                                   ? descriptors[index].fd
                                   : ARES_SOCKET_BAD;
      if (read_fd != ARES_SOCKET_BAD || write_fd != ARES_SOCKET_BAD)
        ares_process_fd(channel, read_fd, write_fd);
    }
  }

  if (!result.done) {
    /* Cancellation completes the callback synchronously. No resolver thread
     * or heap job survives this deadline, including on repeated reconnects. */
    ares_cancel(channel);
    if (result.addresses) ares_freeaddrinfo(result.addresses);
    ares_destroy(channel);
    set_error(error, "DNS resolution timed out");
    return 0;
  }
  if (result.status != ARES_SUCCESS) {
    if (result.addresses) ares_freeaddrinfo(result.addresses);
    ares_destroy(channel);
    set_error(error, ares_strerror(result.status));
    return 0;
  }
  *addresses = result.addresses;
  ares_destroy(channel);
  return 1;
}

static int connect_tcp(const char *host, const char *port, char **error) {
  struct ares_addrinfo *addresses = NULL;
  if (!resolve_bounded(host, port, &addresses, error)) return -1;
  int fd = -1;
  for (struct ares_addrinfo_node *address = addresses->nodes; address;
       address = address->ai_next) {
    fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (fd < 0 || !set_nonblocking(fd)) {
      if (fd >= 0) close(fd);
      fd = -1;
      continue;
    }
    int result = connect(fd, address->ai_addr, address->ai_addrlen);
    if (result == 0 || errno == EINPROGRESS) {
      if (result == 0 || wait_fd(fd, POLLOUT, ft_monotonic_ms() + FT_CONNECT_TIMEOUT_MS) > 0) {
        int socket_error = 0;
        socklen_t length = sizeof(socket_error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &length) == 0 && socket_error == 0)
          break;
      }
    }
    close(fd);
    fd = -1;
  }
  ares_freeaddrinfo(addresses);
  if (fd < 0) set_error(error, "TCP connection failed or timed out");
  return fd;
}

static int socket_write(struct socket_handle *handle, const unsigned char *data,
                        size_t length, int timeout_ms, char **error) {
  size_t written = 0;
  int64_t deadline = ft_monotonic_ms() + timeout_ms;
  while (written < length) {
    int result;
    if (handle->secure) {
      result = SSL_write(handle->ssl, data + written, (int)(length - written));
      if (result <= 0) {
        int ssl_error = SSL_get_error(handle->ssl, result);
        short event = ssl_error == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
        if ((ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) &&
            wait_fd(handle->fd, event, deadline) > 0)
          continue;
        set_error(error, "TLS write failed or timed out");
        return 0;
      }
    } else {
      result = (int)send(handle->fd, data + written, length - written, MSG_NOSIGNAL);
      if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        if (wait_fd(handle->fd, POLLOUT, deadline) > 0) continue;
        set_error(error, "socket write timed out");
        return 0;
      }
      if (result <= 0) {
        set_error(error, "socket write failed");
        return 0;
      }
    }
    written += (size_t)result;
  }
  return 1;
}

/* 1 byte read, 0 clean timeout before data, -1 transport failure. */
static int socket_read_some(struct socket_handle *handle, unsigned char *data,
                            size_t capacity, int64_t deadline, size_t *received) {
  *received = 0;
  for (;;) {
    int result;
    if (handle->secure) {
      result = SSL_read(handle->ssl, data, (int)capacity);
      if (result > 0) {
        *received = (size_t)result;
        return 1;
      }
      int ssl_error = SSL_get_error(handle->ssl, result);
      if (ssl_error == SSL_ERROR_ZERO_RETURN) return -1;
      if (ssl_error != SSL_ERROR_WANT_READ && ssl_error != SSL_ERROR_WANT_WRITE)
        return -1;
      short event = ssl_error == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN;
      int ready = wait_fd(handle->fd, event, deadline);
      if (ready <= 0) return ready;
    } else {
      result = (int)recv(handle->fd, data, capacity, 0);
      if (result > 0) {
        *received = (size_t)result;
        return 1;
      }
      if (result == 0) return -1;
      if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -1;
      int ready = wait_fd(handle->fd, POLLIN, deadline);
      if (ready <= 0) return ready;
    }
  }
}

static int read_exact(struct socket_handle *handle, unsigned char *data,
                      size_t length, int64_t deadline, int *consumed) {
  size_t total = 0;
  while (total < length) {
    size_t received = 0;
    int result = socket_read_some(handle, data + total, length - total, deadline, &received);
    if (result == 0) return *consumed ? -1 : 0;
    if (result < 0) return -1;
    total += received;
    *consumed = 1;
  }
  return 1;
}

static int parse_ws_url(const char *url, int *secure, char **host, char **port,
                        char **path, char **error) {
  const char *rest;
  if (!strncmp(url, "wss://", 6)) {
    *secure = 1;
    rest = url + 6;
  } else if (!strncmp(url, "ws://", 5)) {
    *secure = 0;
    rest = url + 5;
  } else {
    set_error(error, "WebSocket URL must use ws or wss");
    return 0;
  }
  const char *slash = strchr(rest, '/');
  const char *authority_end = slash ? slash : rest + strlen(rest);
  const char *colon = NULL;
  if (*rest == '[') {
    const char *close_bracket = memchr(rest, ']', (size_t)(authority_end - rest));
    if (!close_bracket) {
      set_error(error, "invalid bracketed WebSocket host");
      return 0;
    }
    *host = strndup(rest + 1, (size_t)(close_bracket - rest - 1));
    if (close_bracket + 1 < authority_end && close_bracket[1] == ':') colon = close_bracket + 1;
  } else {
    colon = memchr(rest, ':', (size_t)(authority_end - rest));
    *host = strndup(rest, (size_t)((colon ? colon : authority_end) - rest));
  }
  if (!*host || !**host) {
    free(*host);
    *host = NULL;
    set_error(error, "WebSocket URL omitted host");
    return 0;
  }
  *port = colon ? strndup(colon + 1, (size_t)(authority_end - colon - 1))
                : copy_text(*secure ? "443" : "80");
  *path = copy_text(slash ? slash : "/");
  if (!*port || !**port || !*path) {
    free(*host); free(*port); free(*path);
    *host = *port = *path = NULL;
    set_error(error, "invalid WebSocket URL");
    return 0;
  }
  return 1;
}

static int tls_handshake(struct socket_handle *handle, const char *host,
                         char **error) {
  handle->context = SSL_CTX_new(TLS_client_method());
  if (!handle->context || SSL_CTX_set_default_verify_paths(handle->context) != 1) {
    set_error(error, "could not configure TLS trust store");
    return 0;
  }
  SSL_CTX_set_verify(handle->context, SSL_VERIFY_PEER, NULL);
  handle->ssl = SSL_new(handle->context);
  if (!handle->ssl || SSL_set_fd(handle->ssl, handle->fd) != 1 ||
      SSL_set_tlsext_host_name(handle->ssl, host) != 1 || SSL_set1_host(handle->ssl, host) != 1) {
    set_error(error, "could not configure TLS peer verification");
    return 0;
  }
  int64_t deadline = ft_monotonic_ms() + FT_CONNECT_TIMEOUT_MS;
  for (;;) {
    int result = SSL_connect(handle->ssl);
    if (result == 1) return 1;
    int ssl_error = SSL_get_error(handle->ssl, result);
    short event = ssl_error == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN;
    if ((ssl_error != SSL_ERROR_WANT_READ && ssl_error != SSL_ERROR_WANT_WRITE) ||
        wait_fd(handle->fd, event, deadline) <= 0) {
      set_error(error, "TLS handshake failed or timed out");
      return 0;
    }
  }
}

static int header_has_token(const char *response, const char *name,
                            const char *token) {
  size_t name_length = strlen(name), token_length = strlen(token);
  const char *line = strstr(response, "\r\n") + 2;
  while (line && *line && strncmp(line, "\r\n", 2)) {
    const char *end = strstr(line, "\r\n");
    if (!end) return 0;
    if ((size_t)(end - line) > name_length + 1 && !strncasecmp(line, name, name_length) && line[name_length] == ':') {
      const char *at = line + name_length + 1;
      while (at < end) {
        while (at < end && (*at == ' ' || *at == '\t' || *at == ',')) at++;
        const char *finish = at;
        while (finish < end && *finish != ',') finish++;
        while (finish > at && (finish[-1] == ' ' || finish[-1] == '\t')) finish--;
        if ((size_t)(finish - at) == token_length && !strncasecmp(at, token, token_length)) return 1;
        at = finish + 1;
      }
    }
    line = end + 2;
  }
  return 0;
}

static int header_has_exact_value(const char *response, const char *name,
                                  const char *value) {
  size_t name_length = strlen(name), value_length = strlen(value);
  const char *line = strstr(response, "\r\n");
  if (!line) return 0;
  line += 2;
  while (*line && strncmp(line, "\r\n", 2)) {
    const char *end = strstr(line, "\r\n");
    if (!end) return 0;
    if ((size_t)(end - line) > name_length + 1 &&
        !strncasecmp(line, name, name_length) && line[name_length] == ':') {
      const char *at = line + name_length + 1;
      while (at < end && (*at == ' ' || *at == '\t')) at++;
      while (end > at && (end[-1] == ' ' || end[-1] == '\t')) end--;
      return (size_t)(end - at) == value_length && !memcmp(at, value, value_length);
    }
    line = end + 2;
  }
  return 0;
}

static int websocket_handshake(struct socket_handle *handle, const char *host,
                               const char *port, const char *path,
                               const char *version, char **error) {
  unsigned char nonce[16], digest[EVP_MAX_MD_SIZE];
  unsigned int digest_length = 0;
  char key[25], expected[29], request[4096], host_header[1024];
  if (RAND_bytes(nonce, sizeof(nonce)) != 1 || EVP_EncodeBlock((unsigned char *)key, nonce, sizeof(nonce)) != 24) {
    set_error(error, "could not generate WebSocket handshake key");
    return 0;
  }
  key[24] = '\0';
  char accept_source[128];
  snprintf(accept_source, sizeof(accept_source), "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key);
  if (EVP_Digest(accept_source, strlen(accept_source), digest, &digest_length, EVP_sha1(), NULL) != 1 ||
      EVP_EncodeBlock((unsigned char *)expected, digest, digest_length) != 28) {
    set_error(error, "could not calculate WebSocket accept key");
    return 0;
  }
  expected[28] = '\0';
  int default_port = (handle->secure && !strcmp(port, "443")) || (!handle->secure && !strcmp(port, "80"));
  snprintf(host_header, sizeof(host_header), "%s%s%s", host, default_port ? "" : ":", default_port ? "" : port);
  int request_length = snprintf(request, sizeof(request),
      "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nConvex-Client: %s\r\n\r\n",
      path, host_header, key, version);
  if (request_length <= 0 || (size_t)request_length >= sizeof(request) ||
      !socket_write(handle, (unsigned char *)request, (size_t)request_length, FT_WRITE_TIMEOUT_MS, error))
    return 0;
  char response[FT_MAX_HANDSHAKE + 1];
  size_t used = 0;
  int64_t deadline = ft_monotonic_ms() + FT_CONNECT_TIMEOUT_MS;
  while (used < FT_MAX_HANDSHAKE && (used < 4 || memcmp(response + used - 4, "\r\n\r\n", 4))) {
    size_t received = 0;
    int result = socket_read_some(handle, (unsigned char *)response + used, 1, deadline, &received);
    if (result <= 0) {
      set_error(error, "WebSocket handshake response failed or timed out");
      return 0;
    }
    used += received;
  }
  if (used == FT_MAX_HANDSHAKE) {
    set_error(error, "WebSocket handshake headers exceeded limit");
    return 0;
  }
  response[used] = '\0';
  if (strncmp(response, "HTTP/1.1 101 ", 13) ||
      !header_has_token(response, "Upgrade", "websocket") ||
      !header_has_token(response, "Connection", "Upgrade") ||
      !header_has_exact_value(response, "Sec-WebSocket-Accept", expected)) {
    set_error(error, "WebSocket server returned an invalid upgrade response");
    return 0;
  }
  return 1;
}

void *ft_ws_open(const char *url, const char *client_version, char **error) {
  pthread_once(&initialize_once, initialize_libraries);
  *error = NULL;
  int secure = 0;
  char *host = NULL, *port = NULL, *path = NULL;
  if (!parse_ws_url(url, &secure, &host, &port, &path, error)) return NULL;
  int fd = connect_tcp(host, port, error);
  if (fd < 0) {
    free(host); free(port); free(path);
    return NULL;
  }
  struct socket_handle *handle = calloc(1, sizeof(*handle));
  if (!handle) {
    close(fd); free(host); free(port); free(path);
    set_error(error, "out of memory creating WebSocket transport");
    return NULL;
  }
  handle->fd = fd;
  handle->secure = secure;
  int okay = (!secure || tls_handshake(handle, host, error)) &&
             websocket_handshake(handle, host, port, path, client_version, error);
  free(host); free(port); free(path);
  if (!okay) {
    ft_ws_close(handle);
    return NULL;
  }
  return handle;
}

static int send_frame(struct socket_handle *handle, int opcode,
                      const unsigned char *payload, size_t length,
                      int timeout_ms, char **error) {
  if (length > FT_MAX_MESSAGE || (opcode >= 8 && length > 125)) {
    set_error(error, "WebSocket frame exceeds limit");
    return 0;
  }
  unsigned char header[14], mask[4];
  size_t header_length = 0;
  header[header_length++] = (unsigned char)(0x80 | opcode);
  if (length < 126) {
    header[header_length++] = (unsigned char)(0x80 | length);
  } else if (length <= 65535) {
    header[header_length++] = 0x80 | 126;
    header[header_length++] = (unsigned char)(length >> 8);
    header[header_length++] = (unsigned char)length;
  } else {
    header[header_length++] = 0x80 | 127;
    for (int shift = 56; shift >= 0; shift -= 8)
      header[header_length++] = (unsigned char)((uint64_t)length >> shift);
  }
  if (RAND_bytes(mask, sizeof(mask)) != 1) {
    set_error(error, "could not generate WebSocket mask");
    return 0;
  }
  memcpy(header + header_length, mask, sizeof(mask));
  header_length += sizeof(mask);
  unsigned char *encoded = malloc(length ? length : 1);
  if (!encoded) {
    set_error(error, "out of memory encoding WebSocket frame");
    return 0;
  }
  for (size_t index = 0; index < length; index++) encoded[index] = payload[index] ^ mask[index % 4];
  int okay = socket_write(handle, header, header_length, timeout_ms, error) &&
              socket_write(handle, encoded, length, timeout_ms, error);
  free(encoded);
  return okay;
}

int ft_ws_send(void *opaque, const char *text, size_t length, char **error) {
  *error = NULL;
  return send_frame(opaque, 1, (const unsigned char *)text, length,
                    FT_WRITE_TIMEOUT_MS, error);
}

static int utf8_valid(const unsigned char *data, size_t length) {
  size_t index = 0;
  while (index < length) {
    unsigned char first = data[index++];
    if (first < 0x80) continue;
    int continuation;
    uint32_t value;
    if (first >= 0xC2 && first <= 0xDF) { continuation = 1; value = first & 0x1F; }
    else if (first >= 0xE0 && first <= 0xEF) { continuation = 2; value = first & 0x0F; }
    else if (first >= 0xF0 && first <= 0xF4) { continuation = 3; value = first & 0x07; }
    else return 0;
    if (index + (size_t)continuation > length) return 0;
    for (int offset = 0; offset < continuation; offset++) {
      unsigned char next = data[index++];
      if ((next & 0xC0) != 0x80) return 0;
      value = (value << 6) | (next & 0x3F);
    }
    if ((continuation == 2 && value < 0x800) ||
        (continuation == 3 && value < 0x10000) || value > 0x10FFFF ||
        (value >= 0xD800 && value <= 0xDFFF)) return 0;
  }
  return 1;
}

/* 1 complete message, 0 clean timeout at a frame boundary, -1 abandon socket. */
int ft_ws_receive(void *opaque, char **text, size_t *length, int timeout_ms,
                  char **error) {
  struct socket_handle *handle = opaque;
  *text = NULL; *length = 0; *error = NULL;
  int64_t deadline = ft_monotonic_ms() + timeout_ms;
  for (;;) {
    if (ft_monotonic_ms() >= deadline) return 0;
    unsigned char header[2];
    int consumed = 0;
    int result = read_exact(handle, header, 2, deadline, &consumed);
    if (result == 0) return 0;
    if (result < 0) { set_error(error, "WebSocket frame header failed or timed out"); return -1; }
    int final = (header[0] & 0x80) != 0, opcode = header[0] & 0x0F;
    int masked = (header[1] & 0x80) != 0;
    uint64_t payload_length = header[1] & 0x7F;
    if ((header[0] & 0x70) || masked) {
      set_error(error, "malformed WebSocket frame flags"); return -1;
    }
    if (payload_length == 126) {
      unsigned char wide[2];
      if (read_exact(handle, wide, 2, deadline, &consumed) < 1) { set_error(error, "partial WebSocket length"); return -1; }
      payload_length = ((uint64_t)wide[0] << 8) | wide[1];
      if (payload_length < 126) { set_error(error, "non-canonical WebSocket length"); return -1; }
    } else if (payload_length == 127) {
      unsigned char wide[8];
      if (read_exact(handle, wide, 8, deadline, &consumed) < 1) { set_error(error, "partial WebSocket length"); return -1; }
      if (wide[0] & 0x80) { set_error(error, "invalid WebSocket 64-bit length"); return -1; }
      payload_length = 0;
      for (int index = 0; index < 8; index++) payload_length = (payload_length << 8) | wide[index];
      if (payload_length <= 65535) { set_error(error, "non-canonical WebSocket length"); return -1; }
    }
    if (payload_length > FT_MAX_MESSAGE ||
        handle->fragmented.length > FT_MAX_MESSAGE - (size_t)payload_length) {
      set_error(error, "WebSocket message exceeds 2 MiB"); return -1;
    }
    if (opcode >= 8 && (!final || payload_length > 125)) {
      set_error(error, "malformed WebSocket control frame"); return -1;
    }
    unsigned char *payload = malloc(payload_length ? (size_t)payload_length : 1);
    if (!payload) { set_error(error, "out of memory receiving WebSocket frame"); return -1; }
    if (read_exact(handle, payload, (size_t)payload_length, deadline, &consumed) < 1) {
      free(payload); set_error(error, "partial WebSocket payload timed out"); return -1;
    }
    if (opcode == 8) {
      free(payload); set_error(error, "WebSocket peer closed"); return -1;
    }
    if (opcode == 9) {
      int sent = send_frame(handle, 10, payload, (size_t)payload_length, FT_WRITE_TIMEOUT_MS, error);
      free(payload);
      if (!sent) return -1;
      continue;
    }
    if (opcode == 10) { free(payload); continue; }
    if (opcode != 0 && opcode != 1) { free(payload); set_error(error, "non-text WebSocket data frame"); return -1; }
    if (opcode == 0 && handle->fragment_opcode == 0) { free(payload); set_error(error, "unexpected WebSocket continuation"); return -1; }
    if (opcode == 1 && handle->fragment_opcode != 0) { free(payload); set_error(error, "interleaved WebSocket data message"); return -1; }
    if (opcode == 1) handle->fragment_opcode = 1;
    if (!collect(payload, 1, (size_t)payload_length, &handle->fragmented)) {
      free(payload); set_error(error, "could not buffer WebSocket message"); return -1;
    }
    free(payload);
    if (!final) continue;
    if (!utf8_valid(handle->fragmented.data, handle->fragmented.length)) {
      set_error(error, "WebSocket text was not valid UTF-8"); return -1;
    }
    *text = (char *)handle->fragmented.data;
    *length = handle->fragmented.length;
    handle->fragmented.data = NULL;
    handle->fragmented.length = 0;
    handle->fragment_opcode = 0;
    return 1;
  }
}

void ft_ws_close(void *opaque) {
  struct socket_handle *handle = opaque;
  if (!handle) return;
  char *ignored = NULL;
  if (handle->fd >= 0)
    (void)send_frame(handle, 8, (const unsigned char *)"", 0, 250, &ignored);
  free(ignored);
  if (handle->ssl) {
    (void)SSL_shutdown(handle->ssl);
    SSL_free(handle->ssl);
  }
  if (handle->context) SSL_CTX_free(handle->context);
  if (handle->fd >= 0) close(handle->fd);
  free(handle->fragmented.data);
  free(handle);
}

void *ft_mutex_new(void) {
  pthread_mutex_t *mutex = malloc(sizeof(*mutex));
  if (!mutex || pthread_mutex_init(mutex, NULL) != 0) { free(mutex); return NULL; }
  return mutex;
}

void ft_mutex_lock(void *mutex) { pthread_mutex_lock(mutex); }
void ft_mutex_unlock(void *mutex) { pthread_mutex_unlock(mutex); }
void ft_mutex_free(void *mutex) { if (mutex) { pthread_mutex_destroy(mutex); free(mutex); } }

void *ft_cond_new(void) {
  pthread_cond_t *condition = malloc(sizeof(*condition));
  if (!condition || pthread_cond_init(condition, NULL) != 0) { free(condition); return NULL; }
  return condition;
}

int ft_cond_wait(void *condition, void *mutex, int timeout_ms) {
  if (timeout_ms < 0) return pthread_cond_wait(condition, mutex) == 0 ? 1 : -1;
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
  int result = pthread_cond_timedwait(condition, mutex, &deadline);
  return result == 0 ? 1 : result == ETIMEDOUT ? 0 : -1;
}

void ft_cond_broadcast(void *condition) { pthread_cond_broadcast(condition); }
void ft_cond_free(void *condition) { if (condition) { pthread_cond_destroy(condition); free(condition); } }

void *ft_thread_start(ft_thread_function function, void *argument) {
  struct thread_handle *handle = malloc(sizeof(*handle));
  if (!handle || pthread_create(&handle->thread, NULL, function, argument) != 0) { free(handle); return NULL; }
  return handle;
}

void ft_thread_join(void *opaque) {
  struct thread_handle *handle = opaque;
  if (!handle) return;
  pthread_join(handle->thread, NULL);
  free(handle);
}

int ft_thread_join_bounded(void *opaque, int timeout_ms) {
  struct thread_handle *handle = opaque;
  if (!handle) return 1;
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec++;
    deadline.tv_nsec -= 1000000000L;
  }
  int joined = pthread_timedjoin_np(handle->thread, NULL, &deadline);
  if (joined != 0) return 0;
  free(handle);
  return 1;
}

static int parse_listen(const char *address, char **host, char **port) {
  const char *colon = strrchr(address, ':');
  if (!colon || colon == address || !colon[1]) return 0;
  *host = strndup(address, (size_t)(colon - address));
  *port = copy_text(colon + 1);
  return *host && *port;
}

void *ft_stream_open(const char *listen_address, char **error) {
  *error = NULL;
  struct stream_handle *stream = calloc(1, sizeof(*stream));
  if (!stream) { set_error(error, "out of memory creating adapter stream"); return NULL; }
  pthread_mutex_init(&stream->output_mutex, NULL);
  if (!listen_address || !*listen_address) {
    stream->input_fd = STDIN_FILENO;
    stream->output_fd = STDOUT_FILENO;
    if (!set_nonblocking(stream->output_fd)) {
      set_error(error, "could not make adapter stdout nonblocking");
      ft_stream_close(stream);
      return NULL;
    }
    return stream;
  }
  char *host = NULL, *port = NULL;
  if (!parse_listen(listen_address, &host, &port)) {
    set_error(error, "ADAPTER_LISTEN must be host:port");
    ft_stream_close(stream);
    return NULL;
  }
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM,
                           .ai_flags = AI_PASSIVE | AI_NUMERICHOST | AI_NUMERICSERV};
  struct addrinfo *addresses = NULL;
  int lookup = getaddrinfo(host, port, &hints, &addresses);
  free(host); free(port);
  if (lookup != 0) {
    set_error(error, gai_strerror(lookup));
    ft_stream_close(stream);
    return NULL;
  }
  int listener = -1;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    listener = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (listener < 0) continue;
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    if (bind(listener, address->ai_addr, address->ai_addrlen) == 0 && listen(listener, 1) == 0) break;
    close(listener); listener = -1;
  }
  freeaddrinfo(addresses);
  if (listener < 0) {
    set_error(error, "could not bind adapter TCP listener");
    ft_stream_close(stream);
    return NULL;
  }
  int peer;
  do { peer = accept(listener, NULL, NULL); } while (peer < 0 && errno == EINTR);
  close(listener);
  if (peer < 0) {
    set_error(error, "could not accept adapter TCP controller");
    ft_stream_close(stream);
    return NULL;
  }
  if (!set_nonblocking(peer)) {
    close(peer);
    set_error(error, "could not make adapter controller nonblocking");
    ft_stream_close(stream);
    return NULL;
  }
  stream->input_fd = peer;
  stream->output_fd = peer;
  stream->owns_fds = 1;
  return stream;
}

int ft_stream_readline(void *opaque, char **line, size_t *length,
                       size_t maximum, char **error) {
  struct stream_handle *stream = opaque;
  *line = NULL; *length = 0; *error = NULL;
  struct bytes buffer = {0};
  int oversized = 0;
  for (;;) {
    unsigned char byte;
    ssize_t received = read(stream->input_fd, &byte, 1);
    if (received == 0) {
      if (!buffer.length && !oversized) { free(buffer.data); return 0; }
      break;
    }
    if (received < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        struct pollfd descriptor = {.fd = stream->input_fd, .events = POLLIN};
        int ready;
        do { ready = poll(&descriptor, 1, -1); } while (ready < 0 && errno == EINTR);
        if (ready > 0) continue;
      }
      free(buffer.data); set_error(error, "adapter input read failed"); return -1;
    }
    if (byte == '\n') break;
    if (byte == '\r') continue;
    if (buffer.length >= maximum) { oversized = 1; continue; }
    if (!collect(&byte, 1, 1, &buffer)) {
      free(buffer.data); set_error(error, "adapter input allocation failed"); return -1;
    }
  }
  if (oversized) { free(buffer.data); return -2; }
  if (!utf8_valid(buffer.data, buffer.length)) { free(buffer.data); return -3; }
  *line = (char *)buffer.data;
  *length = buffer.length;
  return 1;
}

int ft_stream_write(void *opaque, const char *text, size_t length,
                    int timeout_ms, char **error) {
  struct stream_handle *stream = opaque;
  *error = NULL;
  pthread_mutex_lock(&stream->output_mutex);
  size_t total = 0;
  int64_t deadline = ft_monotonic_ms() + timeout_ms;
  while (total < length) {
    ssize_t written = stream->owns_fds
      ? send(stream->output_fd, text + total, length - total, MSG_NOSIGNAL)
      : write(stream->output_fd, text + total, length - total);
    if (written > 0) { total += (size_t)written; continue; }
    if (written < 0 && errno == EINTR) continue;
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) &&
        wait_fd(stream->output_fd, POLLOUT, deadline) > 0) continue;
    set_error(error, "adapter output write failed or timed out");
    pthread_mutex_unlock(&stream->output_mutex);
    return 0;
  }
  pthread_mutex_unlock(&stream->output_mutex);
  return 1;
}

void ft_stream_close(void *opaque) {
  struct stream_handle *stream = opaque;
  if (!stream) return;
  if (stream->owns_fds) close(stream->input_fd);
  pthread_mutex_destroy(&stream->output_mutex);
  free(stream);
}

size_t ft_string_length(const char *text) { return text ? strlen(text) : 0; }
void ft_free(void *pointer) { free(pointer); }

#ifdef FORTRAN_TRANSPORT_TESTING
int ft_test_resolver_started(void) { return test_resolver_started != 0; }
int ft_test_thread_count(void) {
  DIR *tasks = opendir("/proc/self/task");
  if (!tasks) return -1;
  int count = 0;
  struct dirent *entry;
  while ((entry = readdir(tasks))) {
    if (entry->d_name[0] != '.') count++;
  }
  closedir(tasks);
  return count;
}
void ft_test_sleep_ms(int milliseconds) {
  struct timespec pause = {.tv_sec = milliseconds / 1000,
                           .tv_nsec = (long)(milliseconds % 1000) * 1000000L};
  nanosleep(&pause, NULL);
}
#endif
