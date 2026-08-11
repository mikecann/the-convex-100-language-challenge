#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { LARGE_VALUE_BYTES = 1900000 };

static void fail(const char *message) {
  perror(message);
  exit(1);
}

static void send_all(int fd, const void *data, size_t length) {
  const unsigned char *cursor = data;
  while (length > 0) {
    ssize_t written = send(fd, cursor, length, MSG_NOSIGNAL);
    if (written < 0 && errno == EINTR) {
      continue;
    }
    if (written <= 0) {
      fail("send");
    }
    cursor += (size_t)written;
    length -= (size_t)written;
  }
}

static int listen_on(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    fail("socket");
  }
  int enabled = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) < 0) {
    fail("setsockopt");
  }
  struct sockaddr_in address = {.sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_ANY),
                                .sin_port = htons(port)};
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 ||
      listen(fd, 1) < 0) {
    fail("bind/listen");
  }
  return fd;
}

static void run_server(void) {
  int listener = listen_on(43143);
  puts("lolcode large HTTP fixture: ready");
  fflush(stdout);
  int client = accept(listener, NULL, NULL);
  if (client < 0) {
    fail("accept");
  }

  // libcurl sends the small request in one write. Reading through the header
  // and body keeps this fixture honest without retaining the request itself.
  char request[8192];
  size_t used = 0;
  size_t expected = SIZE_MAX;
  while (used < sizeof(request)) {
    ssize_t received = recv(client, request + used, sizeof(request) - used, 0);
    if (received <= 0) {
      fail("recv request");
    }
    used += (size_t)received;
    char *header_end = used >= 4 ? strstr(request, "\r\n\r\n") : NULL;
    if (header_end != NULL && expected == SIZE_MAX) {
      size_t header_bytes = (size_t)(header_end + 4 - request);
      char *length = strstr(request, "Content-Length:");
      if (length == NULL) {
        fail("missing Content-Length");
      }
      expected = header_bytes + (size_t)strtoul(length + 15, NULL, 10);
    }
    if (expected != SIZE_MAX && used >= expected) {
      break;
    }
  }

  const char prefix[] = "{\"status\":\"success\",\"value\":\"";
  const char suffix[] = "\",\"logLines\":[]}";
  size_t body_length = sizeof(prefix) - 1 + LARGE_VALUE_BYTES + sizeof(suffix) - 1;
  char header[256];
  int header_length = snprintf(header, sizeof(header),
                               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                               "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                               body_length);
  send_all(client, header, (size_t)header_length);
  send_all(client, prefix, sizeof(prefix) - 1);
  char block[16384];
  memset(block, 'x', sizeof(block));
  size_t remaining = LARGE_VALUE_BYTES;
  while (remaining > 0) {
    size_t chunk = remaining < sizeof(block) ? remaining : sizeof(block);
    send_all(client, block, chunk);
    remaining -= chunk;
  }
  send_all(client, suffix, sizeof(suffix) - 1);
  close(client);
  close(listener);
}

static int connect_retry(const char *host, const char *port) {
  struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM};
  struct addrinfo *addresses = NULL;
  if (getaddrinfo(host, port, &hints, &addresses) != 0) {
    fail("getaddrinfo");
  }
  struct timespec pause = {.tv_sec = 0, .tv_nsec = 20000000};
  for (int attempt = 0; attempt < 150; ++attempt) {
    int fd = socket(addresses->ai_family, addresses->ai_socktype,
                    addresses->ai_protocol);
    if (fd >= 0 && connect(fd, addresses->ai_addr, addresses->ai_addrlen) == 0) {
      freeaddrinfo(addresses);
      return fd;
    }
    if (fd >= 0) {
      close(fd);
    }
    nanosleep(&pause, NULL);
  }
  freeaddrinfo(addresses);
  fail("connect adapter");
  return -1;
}

static void run_controller(const char *host, const char *port) {
  int adapter = connect_retry(host, port);
  const char command[] =
      "{\"id\":\"large\",\"op\":\"query\",\"path\":\"counter:large\","
      "\"args\":{}}\n";
  send_all(adapter, command, sizeof(command) - 1);

  // Never read the near-maximum result. The adapter must block with bounded
  // memory instead of accumulating copies while its controller is stopped.
  sleep(3);

  char received[16384];
  size_t result_bytes = 0;
  int result_complete = 0;
  while (!result_complete) {
    ssize_t count = recv(adapter, received, sizeof(received), 0);
    if (count <= 0) {
      fail("recv large result");
    }
    result_bytes += (size_t)count;
    result_complete = memchr(received, '\n', (size_t)count) != NULL;
  }
  if (result_bytes < LARGE_VALUE_BYTES) {
    fputs("adapter result was not near the maximum size\n", stderr);
    exit(1);
  }

  const char close_command[] = "{\"id\":\"close\",\"op\":\"close\"}\n";
  send_all(adapter, close_command, sizeof(close_command) - 1);
  ssize_t close_bytes = recv(adapter, received, sizeof(received) - 1, 0);
  if (close_bytes <= 0) {
    fail("recv close event");
  }
  received[close_bytes] = '\0';
  if (strstr(received, "\"type\":\"closed\"") == NULL) {
    fputs("adapter omitted its close event\n", stderr);
    exit(1);
  }
  close(adapter);
  puts("lolcode stopped-reader controller: ok");
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  if (argc == 2 && strcmp(argv[1], "server") == 0) {
    run_server();
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "controller") == 0) {
    run_controller(argv[2], argv[3]);
    return 0;
  }
  fprintf(stderr, "usage: %s server | controller HOST PORT\n", argv[0]);
  return 2;
}
