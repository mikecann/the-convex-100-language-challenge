#define _POSIX_C_SOURCE 200809L

#include "../curl_transport.h"

#include <arpa/inet.h>
#include <errno.h>
#include <openssl/evp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

struct fixture {
  int listener;
  int mode;
  int okay;
};

static int write_all(int fd, const void *data, size_t length) {
  const unsigned char *bytes = data;
  while (length) {
    ssize_t sent = send(fd, bytes, length, MSG_NOSIGNAL);
    if (sent < 0 && errno == EINTR) continue;
    if (sent <= 0) return 0;
    bytes += sent;
    length -= (size_t)sent;
  }
  return 1;
}

static int read_all(int fd, void *data, size_t length) {
  unsigned char *bytes = data;
  while (length) {
    ssize_t received = recv(fd, bytes, length, 0);
    if (received < 0 && errno == EINTR) continue;
    if (received <= 0) return 0;
    bytes += received;
    length -= (size_t)received;
  }
  return 1;
}

static int send_frame(int fd, int final, int opcode, const void *payload,
                      size_t length) {
  unsigned char header[4];
  if (length > 125) return 0;
  header[0] = (unsigned char)((final ? 0x80 : 0) | opcode);
  header[1] = (unsigned char)length;
  return write_all(fd, header, 2) && write_all(fd, payload, length);
}

static int upgrade(int fd, int valid) {
  char request[16385];
  size_t used = 0;
  while (used < sizeof(request) - 1) {
    if (!read_all(fd, request + used, 1)) return 0;
    used++;
    if (used >= 4 && !memcmp(request + used - 4, "\r\n\r\n", 4)) break;
  }
  request[used] = '\0';
  const char *at = strstr(request, "Sec-WebSocket-Key: ");
  if (!at) return 0;
  at += strlen("Sec-WebSocket-Key: ");
  const char *end = strstr(at, "\r\n");
  if (!end || end - at != 24) return 0;
  char source[128], accept[29];
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int digest_length = 0;
  snprintf(source, sizeof(source), "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
           (int)(end - at), at);
  if (EVP_Digest(source, strlen(source), digest, &digest_length, EVP_sha1(), NULL) != 1)
    return 0;
  EVP_EncodeBlock((unsigned char *)accept, digest, digest_length);
  accept[28] = '\0';
  if (!valid) accept[0] = accept[0] == 'A' ? 'B' : 'A';
  char response[512];
  int length = snprintf(response, sizeof(response),
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept);
  return length > 0 && write_all(fd, response, (size_t)length);
}

static int receive_masked_hello(int fd) {
  unsigned char header[2], mask[4], encoded[5];
  if (!read_all(fd, header, 2) || header[0] != 0x81 || header[1] != 0x85 ||
      !read_all(fd, mask, 4) || !read_all(fd, encoded, 5)) return 0;
  for (int index = 0; index < 5; index++) encoded[index] ^= mask[index % 4];
  return !memcmp(encoded, "hello", 5);
}

static int receive_masked_pong(int fd) {
  unsigned char header[2], mask[4], encoded;
  if (!read_all(fd, header, 2) || header[0] != 0x8a || header[1] != 0x81 ||
      !read_all(fd, mask, 4) || !read_all(fd, &encoded, 1)) return 0;
  return (unsigned char)(encoded ^ mask[0]) == 'p';
}

static void *serve(void *opaque) {
  struct fixture *fixture = opaque;
  int fd = accept(fixture->listener, NULL, NULL);
  close(fixture->listener);
  if (fd < 0) return NULL;
  if (fixture->mode == 7) {
    fixture->okay = 1;
    struct timespec pause = {.tv_sec = 11, .tv_nsec = 0};
    nanosleep(&pause, NULL);
    close(fd);
    return NULL;
  }
  if (!upgrade(fd, fixture->mode != 5)) {
    close(fd);
    return NULL;
  }
  if (fixture->mode == 5) {
    fixture->okay = 1;
    close(fd);
    return NULL;
  }
  if (fixture->mode == 1) {
    static const unsigned char first[] = {'{', '"', 'x', '"', ':', '"', 0xe2};
    static const unsigned char last[] = {0x82, 0xac, '"', '}'};
    fixture->okay = receive_masked_hello(fd) &&
      send_frame(fd, 0, 1, first, sizeof(first)) &&
      send_frame(fd, 1, 9, "p", 1) &&
      receive_masked_pong(fd) &&
      send_frame(fd, 1, 0, last, sizeof(last));
  } else if (fixture->mode == 2) {
    unsigned char partial[] = {0x81, 0x05, 'x'};
    fixture->okay = write_all(fd, partial, sizeof(partial));
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 300000000};
    nanosleep(&pause, NULL);
  } else if (fixture->mode == 3) {
    unsigned char malformed[] = {0x09, 0x00};
    fixture->okay = write_all(fd, malformed, sizeof(malformed));
  } else if (fixture->mode == 4) {
    fixture->okay = 1;
    for (int index = 0; index < 10000; index++) {
      if (!send_frame(fd, 1, 1, "x", 1)) break;
    }
  } else if (fixture->mode == 6) {
    fixture->okay = 1;
    for (int index = 0; index < 10000; index++) {
      if (!send_frame(fd, 1, 9, "p", 1) || !receive_masked_pong(fd)) break;
    }
  } else if (fixture->mode == 8) {
    int receive_buffer = 4096;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer, sizeof(receive_buffer));
    fixture->okay = 1;
    struct timespec pause = {.tv_sec = 3, .tv_nsec = 0};
    nanosleep(&pause, NULL);
  }
  close(fd);
  return NULL;
}

static int start_fixture(struct fixture *fixture, pthread_t *thread, int mode,
                         char url[64]) {
  fixture->listener = socket(AF_INET, SOCK_STREAM, 0);
  fixture->mode = mode;
  fixture->okay = 0;
  if (fixture->listener < 0) return 0;
  int yes = 1;
  setsockopt(fixture->listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(fixture->listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
      listen(fixture->listener, 1) != 0) return 0;
  socklen_t length = sizeof(address);
  if (getsockname(fixture->listener, (struct sockaddr *)&address, &length) != 0) return 0;
  snprintf(url, 64, "ws://127.0.0.1:%u/api/sync", ntohs(address.sin_port));
  return pthread_create(thread, NULL, serve, fixture) == 0;
}

static void fail(const char *message) {
  fprintf(stderr, "FAIL %s\n", message);
  exit(1);
}

int main(void) {
  for (int mode = 1; mode <= 8; mode++) {
    struct fixture fixture;
    pthread_t thread;
    char url[64], *error = NULL;
    if (!start_fixture(&fixture, &thread, mode, url)) fail("could not start socket fixture");
    int64_t started = ft_monotonic_ms();
    void *socket = ft_ws_open(url, "fortran-test", &error);
    if (mode == 5) {
      if (socket || ft_monotonic_ms() - started > 1000) fail("invalid handshake was accepted or unbounded");
      free(error);
      pthread_join(thread, NULL);
      if (!fixture.okay) fail("invalid handshake fixture failed");
      continue;
    }
    if (mode == 7) {
      int64_t elapsed = ft_monotonic_ms() - started;
      if (socket || elapsed < 9000 || elapsed > 10500)
        fail("silent handshake peer escaped the ten-second deadline");
      free(error);
      pthread_join(thread, NULL);
      if (!fixture.okay) fail("silent handshake fixture failed");
      continue;
    }
    if (!socket) fail(error ? error : "fixture handshake failed");
    if (mode == 1) {
      if (!ft_ws_send(socket, "hello", 5, &error)) fail(error);
      char *message = NULL;
      size_t length = 0;
      if (ft_ws_receive(socket, &message, &length, 1000, &error) != 1 ||
          length != 11 || memcmp(message, "{\"x\":\"\342\202\254\"}", 11))
        fail(error ? error : "fragmented UTF-8/control-frame decode failed");
      free(message);
    } else if (mode == 2) {
      char *message = NULL;
      size_t length = 0;
      started = ft_monotonic_ms();
      if (ft_ws_receive(socket, &message, &length, 100, &error) != -1 ||
          ft_monotonic_ms() - started > 500)
        fail("partial frame was restarted or unbounded");
      free(error);
      error = NULL;
    } else if (mode == 3) {
      char *message = NULL;
      size_t length = 0;
      if (ft_ws_receive(socket, &message, &length, 500, &error) != -1)
        fail("fragmented control frame was accepted");
      free(error);
      error = NULL;
    } else if (mode == 6) {
      char *message = NULL;
      size_t length = 0;
      started = ft_monotonic_ms();
      if (ft_ws_receive(socket, &message, &length, 100, &error) != 0 ||
          ft_monotonic_ms() - started > 700)
        fail("continuous control traffic escaped receive deadline");
    } else if (mode == 8) {
      char *payload = malloc(2U * 1024U * 1024U);
      if (!payload) fail("write-stall payload allocation");
      memset(payload, 'x', 2U * 1024U * 1024U);
      started = ft_monotonic_ms();
      int sent = 1;
      for (int attempt = 0; attempt < 4 && sent; attempt++)
        sent = ft_ws_send(socket, payload, 2U * 1024U * 1024U, &error);
      free(payload);
      if (sent || ft_monotonic_ms() - started > 1500)
        fail("stalled peer escaped the WebSocket write deadline");
      free(error);
      error = NULL;
    }
    started = ft_monotonic_ms();
    ft_ws_close(socket);
    if (ft_monotonic_ms() - started > 500) fail("close exceeded its deadline");
    pthread_join(thread, NULL);
    if (!fixture.okay) fail("socket fixture did not complete");
  }
  puts("PASS RFC6455 socket adversarial fixtures");
  return 0;
}
