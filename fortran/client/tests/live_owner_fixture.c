#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <openssl/evp.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static pthread_t fixture_thread;
static pthread_mutex_t fixture_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fixture_condition = PTHREAD_COND_INITIALIZER;
static int listener = -1;
static int command_pipe[2] = {-1, -1};
static int connection_count;
static int add_count;
static int remove_count;
static int current_value;
static int running;

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

static int upgrade(int fd) {
  char request[16385];
  size_t used = 0;
  while (used < sizeof(request) - 1) {
    if (!read_all(fd, request + used, 1)) return 0;
    used++;
    if (used >= 4 && !memcmp(request + used - 4, "\r\n\r\n", 4)) break;
  }
  request[used] = '\0';
  const char *key = strstr(request, "Sec-WebSocket-Key: ");
  if (!key) return 0;
  key += strlen("Sec-WebSocket-Key: ");
  const char *end = strstr(key, "\r\n");
  if (!end || end - key != 24) return 0;
  char source[128], accept[29], response[512];
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int digest_length = 0;
  snprintf(source, sizeof(source), "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
           (int)(end - key), key);
  if (EVP_Digest(source, strlen(source), digest, &digest_length, EVP_sha1(), NULL) != 1)
    return 0;
  EVP_EncodeBlock((unsigned char *)accept, digest, digest_length);
  accept[28] = '\0';
  int length = snprintf(response, sizeof(response),
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      "Sec-WebSocket-Accept: %s\r\n\r\n", accept);
  return length > 0 && write_all(fd, response, (size_t)length);
}

static int read_client_frame(int fd, int *opcode, char **text) {
  unsigned char header[2], mask[4], wide[8];
  if (!read_all(fd, header, 2)) return 0;
  *opcode = header[0] & 15;
  if (!(header[1] & 0x80)) return 0;
  uint64_t length = header[1] & 127;
  if (length == 126) {
    if (!read_all(fd, wide, 2)) return 0;
    length = ((uint64_t)wide[0] << 8) | wide[1];
  } else if (length == 127) {
    if (!read_all(fd, wide, 8)) return 0;
    length = 0;
    for (int index = 0; index < 8; index++) length = (length << 8) | wide[index];
  }
  if (length > 2 * 1024 * 1024 || !read_all(fd, mask, 4)) return 0;
  char *payload = malloc((size_t)length + 1);
  if (!payload || !read_all(fd, payload, (size_t)length)) {
    free(payload);
    return 0;
  }
  for (size_t index = 0; index < length; index++) payload[index] ^= mask[index % 4];
  payload[length] = '\0';
  *text = payload;
  return 1;
}

static int send_text(int fd, const char *text) {
  size_t length = strlen(text);
  unsigned char header[4];
  size_t header_length;
  header[0] = 0x81;
  if (length < 126) {
    header[1] = (unsigned char)length;
    header_length = 2;
  } else {
    header[1] = 126;
    header[2] = (unsigned char)(length >> 8);
    header[3] = (unsigned char)length;
    header_length = 4;
  }
  return write_all(fd, header, header_length) && write_all(fd, text, length);
}

static void timestamp_text(unsigned number, char encoded[13]) {
  static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  unsigned char bytes[9] = {0};
  for (int index = 0; index < 8; index++) {
    bytes[index] = (unsigned char)(number & 255);
    number >>= 8;
  }
  int at = 0;
  for (int index = 0; index < 9; index += 3) {
    unsigned triple = ((unsigned)bytes[index] << 16) |
      ((unsigned)bytes[index + 1] << 8) | bytes[index + 2];
    encoded[at++] = alphabet[(triple >> 18) & 63];
    encoded[at++] = alphabet[(triple >> 12) & 63];
    encoded[at++] = alphabet[(triple >> 6) & 63];
    encoded[at++] = alphabet[triple & 63];
  }
  encoded[11] = '=';
  encoded[12] = '\0';
}

static int send_transition(int fd, unsigned start, unsigned finish, int failed,
                           int removed) {
  char start_ts[13], end_ts[13], message[2048];
  timestamp_text(start, start_ts);
  timestamp_text(finish, end_ts);
  int length;
  if (failed) {
    length = snprintf(message, sizeof(message),
      "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},\"modifications\":["
      "{\"type\":\"QueryFailed\",\"queryId\":0,\"errorMessage\":\"fixture failure\","
      "\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[]}]}",
      start == 0 ? 0 : 1, start_ts, end_ts);
  } else if (removed) {
    length = snprintf(message, sizeof(message),
      "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},"
      "\"endVersion\":{\"querySet\":2,\"identity\":0,\"ts\":\"%s\"},\"modifications\":["
      "{\"type\":\"QueryRemoved\",\"queryId\":0}]}", start_ts, end_ts);
  } else {
    length = snprintf(message, sizeof(message),
      "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},\"modifications\":["
      "{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":%d},\"logLines\":[]}]}",
      start == 0 ? 0 : 1, start_ts, end_ts, current_value);
  }
  return length > 0 && (size_t)length < sizeof(message) && send_text(fd, message);
}

static int send_invalid_logs_transition(int fd, unsigned start,
                                        unsigned finish, int mixed) {
  char start_ts[13], end_ts[13], message[2048];
  timestamp_text(start, start_ts);
  timestamp_text(finish, end_ts);
  const char *logs = mixed ? "[\"valid\",7]" : "null";
  int length = snprintf(message, sizeof(message),
    "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},"
    "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},\"modifications\":["
    "{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":%d},\"logLines\":%s}]}",
    start_ts, end_ts, current_value, logs);
  return length > 0 && (size_t)length < sizeof(message) && send_text(fd, message);
}

static void record_connection(int added) {
  pthread_mutex_lock(&fixture_mutex);
  connection_count++;
  if (added) add_count++;
  pthread_cond_broadcast(&fixture_condition);
  pthread_mutex_unlock(&fixture_mutex);
}

static void *serve(void *unused) {
  (void)unused;
  while (running) {
    struct pollfd ready[2] = {
        {.fd = listener, .events = POLLIN},
        {.fd = command_pipe[0], .events = POLLIN},
    };
    if (poll(ready, 2, 50) <= 0) continue;
    if (ready[1].revents & POLLIN) {
      char fixture_command;
      if (read(command_pipe[0], &fixture_command, 1) == 1 && fixture_command == 'S') {
        running = 0;
        break;
      }
      continue;
    }
    if (!(ready[0].revents & POLLIN)) continue;
    int peer = accept(listener, NULL, NULL);
    if (peer < 0) continue;
    if (!upgrade(peer)) {
      close(peer);
      continue;
    }
    char *connect = NULL, *add = NULL;
    int opcode;
    if (!read_client_frame(peer, &opcode, &connect) || opcode != 1 ||
        !read_client_frame(peer, &opcode, &add) || opcode != 1) {
      free(connect);
      free(add);
      close(peer);
      continue;
    }
    int requires_nonzero = strstr(add, "requiresNonzero") != NULL;
    int added = strstr(add, "\"type\":\"Add\"") != NULL;
    free(connect);
    free(add);
    record_connection(added);
    unsigned state = 1;
    if (!send_transition(peer, 0, state, requires_nonzero && current_value == 0, 0)) {
      close(peer);
      continue;
    }
    int connected = 1;
    while (running && connected) {
      struct pollfd descriptors[2] = {
        {.fd = peer, .events = POLLIN},
        {.fd = command_pipe[0], .events = POLLIN},
      };
      if (poll(descriptors, 2, 50) <= 0) continue;
      if (descriptors[1].revents & POLLIN) {
        char command;
        if (read(command_pipe[0], &command, 1) != 1) continue;
        if (command == 'U') {
          current_value++;
          if (!send_transition(peer, state, state + 1, 0, 0)) connected = 0;
          state++;
        } else if (command == 'F') {
          if (!send_transition(peer, state, state + 1, 1, 0)) connected = 0;
          state++;
        } else if (command == 'N' || command == 'M') {
          if (!send_invalid_logs_transition(peer, state, state + 1,
                                            command == 'M')) connected = 0;
          state++;
        } else if (command == 'P') {
          send_text(peer, "{\"type\":\"UnknownFixtureMessage\"}");
          connected = 0;
        } else if (command == 'T') {
          connected = 0;
        } else if (command == 'S') {
          running = 0;
          connected = 0;
        }
      }
      if (connected && descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) {
        char *message = NULL;
        if (!read_client_frame(peer, &opcode, &message)) {
          connected = 0;
        } else if (opcode == 8) {
          connected = 0;
        } else if (opcode == 1 && strstr(message, "\"type\":\"Remove\"")) {
          pthread_mutex_lock(&fixture_mutex);
          remove_count++;
          pthread_cond_broadcast(&fixture_condition);
          pthread_mutex_unlock(&fixture_mutex);
          send_transition(peer, state, state + 1, 0, 1);
          state++;
        }
        free(message);
      }
    }
    close(peer);
  }
  return NULL;
}

int ft_live_fixture_start(void) {
  listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0 || pipe(command_pipe) != 0) return 0;
  int yes = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 4) != 0) return 0;
  socklen_t length = sizeof(address);
  if (getsockname(listener, (struct sockaddr *)&address, &length) != 0) return 0;
  connection_count = add_count = remove_count = current_value = 0;
  running = 1;
  if (pthread_create(&fixture_thread, NULL, serve, NULL) != 0) return 0;
  return ntohs(address.sin_port);
}

static void command(char value) {
  if (command_pipe[1] >= 0) (void)write(command_pipe[1], &value, 1);
}

void ft_live_fixture_update(void) { command('U'); }
void ft_live_fixture_function_error(void) { command('F'); }
void ft_live_fixture_null_logs(void) { command('N'); }
void ft_live_fixture_mixed_logs(void) { command('M'); }
void ft_live_fixture_protocol_error(void) { command('P'); }
void ft_live_fixture_transport_error(void) { command('T'); }

int ft_live_fixture_wait_adds(int expected, int timeout_ms) {
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec++;
    deadline.tv_nsec -= 1000000000L;
  }
  pthread_mutex_lock(&fixture_mutex);
  while (add_count < expected) {
    if (pthread_cond_timedwait(&fixture_condition, &fixture_mutex, &deadline) == ETIMEDOUT) break;
  }
  int result = add_count >= expected;
  pthread_mutex_unlock(&fixture_mutex);
  return result;
}

int ft_live_fixture_remove_count(void) {
  pthread_mutex_lock(&fixture_mutex);
  int result = remove_count;
  pthread_mutex_unlock(&fixture_mutex);
  return result;
}

int ft_live_fixture_wait_removes(int expected, int timeout_ms) {
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec++;
    deadline.tv_nsec -= 1000000000L;
  }
  pthread_mutex_lock(&fixture_mutex);
  while (remove_count < expected) {
    if (pthread_cond_timedwait(&fixture_condition, &fixture_mutex, &deadline) == ETIMEDOUT) break;
  }
  int result = remove_count >= expected;
  pthread_mutex_unlock(&fixture_mutex);
  return result;
}

void ft_live_fixture_stop(void) {
  command('S');
  pthread_join(fixture_thread, NULL);
  close(listener);
  close(command_pipe[0]);
  close(command_pipe[1]);
  listener = command_pipe[0] = command_pipe[1] = -1;
}
