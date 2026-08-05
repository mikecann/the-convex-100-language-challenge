#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *message) {
  fprintf(stderr, "FAIL adapter process fixture: %s\n", message);
  exit(1);
}

struct http_fixture {
  int listener;
  pthread_t thread;
};

static void *serve_http_errors(void *opaque) {
  struct http_fixture *fixture = opaque;
  static const char body[] =
      "{\"status\":\"error\",\"errorMessage\":\"fixture failure\","
      "\"errorData\":{\"code\":\"FIXTURE\"},\"logLines\":[\"fixture\"]}";
  for (int request = 0; request < 2; request++) {
    int peer = accept(fixture->listener, NULL, NULL);
    if (peer < 0) return NULL;
    char headers[8192];
    size_t used = 0;
    while (used < sizeof(headers) - 1) {
      ssize_t received = recv(peer, headers + used, 1, 0);
      if (received <= 0) break;
      used += (size_t)received;
      if (used >= 4 && !memcmp(headers + used - 4, "\r\n\r\n", 4)) break;
    }
    headers[used] = '\0';
    const char *content_length = strstr(headers, "Content-Length: ");
    size_t body_length = content_length ? (size_t)strtoul(content_length + 16, NULL, 10) : 0;
    char discard[1024];
    while (body_length) {
      size_t wanted = body_length < sizeof(discard) ? body_length : sizeof(discard);
      ssize_t received = recv(peer, discard, wanted, 0);
      if (received <= 0) break;
      body_length -= (size_t)received;
    }
    char response[1024];
    int length = snprintf(response, sizeof(response),
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n"
        "Connection: close\r\n\r\n%s", strlen(body), body);
    if (length > 0) send(peer, response, (size_t)length, MSG_NOSIGNAL);
    close(peer);
  }
  close(fixture->listener);
  return NULL;
}

static unsigned start_http_fixture(struct http_fixture *fixture) {
  fixture->listener = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (fixture->listener < 0 || bind(fixture->listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
      listen(fixture->listener, 2) != 0) fail("HTTP fixture listen");
  socklen_t length = sizeof(address);
  if (getsockname(fixture->listener, (struct sockaddr *)&address, &length) != 0 ||
      pthread_create(&fixture->thread, NULL, serve_http_errors, fixture) != 0)
    fail("HTTP fixture start");
  return ntohs(address.sin_port);
}

static unsigned reserve_port(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) fail("port bind");
  socklen_t length = sizeof(address);
  if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) fail("port lookup");
  close(fd);
  return ntohs(address.sin_port);
}

static pid_t start_adapter(unsigned port, const char *executable, const char *convex_url) {
  pid_t child = fork();
  if (child < 0) fail("fork");
  if (child == 0) {
    char listen[64];
    snprintf(listen, sizeof(listen), "127.0.0.1:%u", port);
    setenv("ADAPTER_LISTEN", listen, 1);
    if (convex_url) setenv("CONVEX_URL", convex_url, 1);
    execl(executable, executable, (char *)NULL);
    _exit(127);
  }
  return child;
}

static size_t read_to_eof(int fd, char *output, size_t capacity) {
  size_t used = 0;
  while (used < capacity - 1) {
    ssize_t received = read(fd, output + used, capacity - used - 1);
    if (received < 0 && errno == EINTR) continue;
    if (received <= 0) break;
    used += (size_t)received;
  }
  output[used] = '\0';
  return used;
}

static int read_line_bounded(int fd, char *line, size_t capacity, int timeout_ms) {
  size_t used = 0;
  while (used < capacity - 1) {
    struct pollfd descriptor = {.fd = fd, .events = POLLIN};
    int ready = poll(&descriptor, 1, timeout_ms);
    if (ready <= 0) return 0;
    ssize_t received = read(fd, line + used, 1);
    if (received <= 0) return 0;
    if (line[used++] == '\n') break;
  }
  line[used] = '\0';
  return 1;
}

static int connect_adapter(unsigned port) {
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
                                .sin_port = htons((uint16_t)port)};
  struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
  for (int attempt = 0; attempt < 200; attempt++) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) return fd;
    if (fd >= 0) close(fd);
    nanosleep(&pause, NULL);
  }
  fail("connect timeout");
  return -1;
}

static void send_all(int fd, const char *text) {
  size_t length = strlen(text);
  while (length) {
    ssize_t sent = send(fd, text, length, MSG_NOSIGNAL);
    if (sent < 0 && errno == EINTR) continue;
    if (sent <= 0) fail("send");
    text += sent;
    length -= (size_t)sent;
  }
}

static void write_all_fd(int fd, const char *text) {
  size_t length = strlen(text);
  while (length) {
    ssize_t written = write(fd, text, length);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) fail("pipe write");
    text += written;
    length -= (size_t)written;
  }
}

static void wait_bounded(pid_t child) {
  struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
  for (int attempt = 0; attempt < 300; attempt++) {
    int status;
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) {
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("adapter exit status");
      return;
    }
    nanosleep(&pause, NULL);
  }
  kill(child, SIGKILL);
  waitpid(child, NULL, 0);
  fail("adapter EOF cleanup exceeded three seconds");
}

static long resident_kib(pid_t child) {
  char path[64], line[256];
  snprintf(path, sizeof(path), "/proc/%ld/status", (long)child);
  FILE *file = fopen(path, "r");
  if (!file) return -1;
  long value = -1;
  while (fgets(line, sizeof(line), file)) {
    if (sscanf(line, "VmRSS: %ld kB", &value) == 1) break;
  }
  fclose(file);
  return value;
}

int main(void) {
  unsigned port = reserve_port();
  pid_t child = start_adapter(port, "/out-adapter-test", NULL);
  int fd = connect_adapter(port);
  send_all(fd, "{\"id\":\"hello\",\"protocol");
  send_all(fd, "Version\":1,\"op\":\"hello\"}\nnot-json\n");
  send_all(fd, "\300\257\n");
  send_all(fd, "{\"x\":{\"id\":\"nested\",\"op\":\"hello\",\"protocolVersion\":1}}\n");
  send_all(fd, "{\"op\":\"hello\",\"protocolVersion\":1}\n");
  send_all(fd, "{\"id\":\"extra\",\"op\":\"hello\",\"protocolVersion\":1,\"extra\":true}\n");
  send_all(fd, "{\"id\":\"result\",\"op\":\"testResult\"}\n");
  send_all(fd, "{\"id\":\"function\",\"op\":\"testFunctionError\"}\n");
  send_all(fd, "{\"id\":\"subscription\",\"op\":\"testSubscription\"}\n");
  send_all(fd, "{\"id\":\"subscription-error\",\"op\":\"testSubscriptionError\"}\n");
  send_all(fd, "{\"id\":\"close\",\"op\":\"close\"}\n");
  shutdown(fd, SHUT_WR);
  char output[8192];
  read_to_eof(fd, output, sizeof(output));
  close(fd);
  wait_bounded(child);
  char *ready = strstr(output, "\"id\":\"hello\",\"type\":\"ready\"");
  char *malformed = strstr(output, "\"name\":\"ProtocolError\"");
  char *invalid_utf8 = malformed ? strstr(malformed + 1, "not valid UTF-8") : NULL;
  char *closed = strstr(output, "{\"id\":\"close\",\"type\":\"closed\"}");
  if (!ready || !malformed || !invalid_utf8 || !closed ||
      !(ready < malformed && malformed < invalid_utf8 && invalid_utf8 < closed))
    fail("partial/malformed command isolation or ordering");
  if (strstr(output, "\"id\":\"nested\"") || strstr(output, "\"id\":\"extra\"") ||
      strstr(output, "\"id\":\"\",\"type\":\"ready\""))
    fail("nested, missing, or additional command fields executed");
  if (!strstr(output, "{\"id\":\"result\",\"type\":\"result\",\"value\":{\"count\":1},\"logs\":[\"fixture\"]}") ||
      !strstr(output, "{\"type\":\"error\",\"id\":\"function\",\"error\":{\"name\":\"FunctionError\",\"message\":\"fixture failure\",\"data\":{\"code\":\"FIXTURE\"}}}") ||
      !strstr(output, "{\"type\":\"subscription\",\"subscriptionId\":\"fixture-subscription\",\"value\":{\"count\":2},\"logs\":[]}") ||
      !strstr(output, "{\"type\":\"subscription\",\"subscriptionId\":\"fixture-error\",\"error\":{\"name\":\"TransportError\",\"message\":\"fixture transport failure\"}}") ||
      !strstr(output, "{\"id\":\"close\",\"type\":\"closed\"}") ||
      strstr(output, ":null")) {
    fprintf(stderr, "adapter fixture output:\n%s\n", output);
    fail("serialized result, structured error, subscription, or close event shape");
  }

  port = reserve_port();
  child = start_adapter(port, "/out-adapter", NULL);
  fd = connect_adapter(port);
  close(fd);
  wait_bounded(child);

  /* A nonblocking TCP controller is allowed to sit idle between commands. */
  port = reserve_port();
  child = start_adapter(port, "/out-adapter", NULL);
  fd = connect_adapter(port);
  send_all(fd, "{\"id\":\"idle-hello\",\"protocolVersion\":1,\"op\":\"hello\"}\n");
  char line[1024];
  if (!read_line_bounded(fd, line, sizeof(line), 2000) || !strstr(line, "\"type\":\"ready\""))
    fail("idle TCP initial response");
  struct timespec idle_pause = {.tv_sec = 1, .tv_nsec = 0};
  nanosleep(&idle_pause, NULL);
  send_all(fd, "{\"id\":\"idle-close\",\"op\":\"close\"}\n");
  shutdown(fd, SHUT_WR);
  if (!read_line_bounded(fd, line, sizeof(line), 2000) ||
      strcmp(line, "{\"id\":\"idle-close\",\"type\":\"closed\"}\n"))
    fail("idle TCP close response");
  close(fd);
  wait_bounded(child);

  /* Failed initialization must remain an isolated command failure. */
  port = reserve_port();
  child = start_adapter(port, "/out-adapter", "ftp://invalid");
  fd = connect_adapter(port);
  send_all(fd, "{\"id\":\"invalid-1\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n");
  send_all(fd, "{\"id\":\"invalid-2\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n");
  send_all(fd, "{\"id\":\"invalid-close\",\"op\":\"close\"}\n");
  shutdown(fd, SHUT_WR);
  read_to_eof(fd, output, sizeof(output));
  close(fd);
  wait_bounded(child);
  if (!strstr(output, "\"id\":\"invalid-1\"") || !strstr(output, "\"id\":\"invalid-2\"") ||
      !strstr(output, "{\"id\":\"invalid-close\",\"type\":\"closed\"}"))
    fail("repeated client initialization failure isolation");

  /* Exercise real convex_call error decoding and adapter serialization. */
  struct http_fixture http_fixture;
  unsigned http_port = start_http_fixture(&http_fixture);
  char fixture_url[64];
  snprintf(fixture_url, sizeof(fixture_url), "http://127.0.0.1:%u", http_port);
  port = reserve_port();
  child = start_adapter(port, "/out-adapter", fixture_url);
  fd = connect_adapter(port);
  send_all(fd, "{\"id\":\"http-1\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n");
  send_all(fd, "{\"id\":\"http-2\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n");
  send_all(fd, "{\"id\":\"http-close\",\"op\":\"close\"}\n");
  shutdown(fd, SHUT_WR);
  read_to_eof(fd, output, sizeof(output));
  close(fd);
  wait_bounded(child);
  pthread_join(http_fixture.thread, NULL);
  if (!strstr(output, "{\"type\":\"error\",\"id\":\"http-1\",\"error\":{\"name\":\"FunctionError\",\"message\":\"fixture failure\",\"data\":{\"code\":\"FIXTURE\"}}}") ||
      !strstr(output, "{\"type\":\"error\",\"id\":\"http-2\",\"error\":{\"name\":\"FunctionError\",\"message\":\"fixture failure\",\"data\":{\"code\":\"FIXTURE\"}}}"))
    fail("real HTTP structured error serialization");

  port = reserve_port();
  child = start_adapter(port, "/out-adapter-test", NULL);
  fd = connect_adapter(port);
  for (int index = 0; index < 24; index++) {
    char command[96];
    snprintf(command, sizeof(command), "{\"id\":\"large-%d\",\"op\":\"testLargeEvent\"}\n", index);
    send_all(fd, command);
  }
  struct timespec fill_pause = {.tv_sec = 0, .tv_nsec = 100000000};
  nanosleep(&fill_pause, NULL);
  long memory = resident_kib(child);
  if (memory < 0 || memory >= 100 * 1024) fail("stopped-reader memory bound");
  shutdown(fd, SHUT_WR);
  close(fd);
  wait_bounded(child);

  /* stdin/stdout mode must also abandon a stopped reader on its write deadline. */
  int input_pipe[2], output_pipe[2];
  if (pipe(input_pipe) != 0 || pipe(output_pipe) != 0) fail("stdio backpressure pipes");
  child = fork();
  if (child < 0) fail("stdio backpressure fork");
  if (child == 0) {
    dup2(input_pipe[0], STDIN_FILENO);
    dup2(output_pipe[1], STDOUT_FILENO);
    close(input_pipe[0]); close(input_pipe[1]); close(output_pipe[0]); close(output_pipe[1]);
    execl("/out-adapter-test", "/out-adapter-test", (char *)NULL);
    _exit(127);
  }
  close(input_pipe[0]); close(output_pipe[1]);
  write_all_fd(input_pipe[1], "{\"id\":\"stdio-large\",\"op\":\"testLargeEvent\"}\n");
  close(input_pipe[1]);
  wait_bounded(child);
  close(output_pipe[0]);

  puts("PASS adapter TCP partial input, isolation, backpressure, and EOF cleanup");
  return 0;
}
