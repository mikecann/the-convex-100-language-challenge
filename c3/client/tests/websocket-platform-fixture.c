#define _POSIX_C_SOURCE 200809L
#include <openssl/evp.h>
#include <openssl/ssl.h>

#include <arpa/inet.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

void *c3_ws_connect(const char *url, const char *ca_path, long timeout_millis);
int c3_ws_is_active(void *websocket);
int c3_ws_send_text(void *websocket, const char *data, size_t length, long timeout_millis);
int c3_ws_receive_text(void *websocket, char *output, size_t capacity,
                       size_t *length, long timeout_millis);
int c3_ws_close(void *websocket, long timeout_millis);
void c3_ws_free(void *websocket);

enum server_mode { HAPPY, PARTIAL_FRAME, STALLED };

static void fail(const char *message) {
  fprintf(stderr, "websocket fixture: %s\n", message);
  exit(1);
}

static int64_t monotonic_millis(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int ssl_read_exact(SSL *ssl, unsigned char *output, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    int received = SSL_read(ssl, output + offset, (int)(length - offset));
    if (received <= 0) return 0;
    offset += (size_t)received;
  }
  return 1;
}

static int ssl_write_all(SSL *ssl, const void *data, size_t length) {
  const unsigned char *bytes = data;
  size_t offset = 0;
  while (offset < length) {
    int sent = SSL_write(ssl, bytes + offset, (int)(length - offset));
    if (sent <= 0) return 0;
    offset += (size_t)sent;
  }
  return 1;
}

static int websocket_accept(const char *request, char output[29]) {
  const char *header = strstr(request, "Sec-WebSocket-Key: ");
  if (!header) return 0;
  header += strlen("Sec-WebSocket-Key: ");
  const char *end = strstr(header, "\r\n");
  if (!end || end - header > 64) return 0;
  char source[128];
  int written = snprintf(source, sizeof source, "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
                         (int)(end - header), header);
  if (written <= 0 || written >= (int)sizeof source) return 0;
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int digest_length = 0;
  EVP_MD_CTX *context = EVP_MD_CTX_new();
  if (!context) return 0;
  int ok = EVP_DigestInit_ex(context, EVP_sha1(), NULL) == 1 &&
           EVP_DigestUpdate(context, source, (size_t)written) == 1 &&
           EVP_DigestFinal_ex(context, digest, &digest_length) == 1;
  EVP_MD_CTX_free(context);
  if (!ok || digest_length != 20) return 0;
  return EVP_EncodeBlock((unsigned char *)output, digest, (int)digest_length) == 28;
}

static int perform_upgrade(SSL *ssl) {
  char request[8192] = {0};
  size_t length = 0;
  while (!strstr(request, "\r\n\r\n") && length < sizeof request - 1) {
    int received = SSL_read(ssl, request + length, (int)(sizeof request - length - 1));
    if (received <= 0) return 0;
    length += (size_t)received;
    request[length] = '\0';
  }
  char accept[29] = {0};
  if (!websocket_accept(request, accept)) return 0;
  char response[512];
  int response_length = snprintf(response, sizeof response,
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: %s\r\n\r\n", accept);
  return response_length > 0 && response_length < (int)sizeof response &&
         ssl_write_all(ssl, response, (size_t)response_length);
}

static int send_server_frame(SSL *ssl, int final, unsigned char opcode,
                             const char *payload, size_t length) {
  if (length > 125) return 0;
  unsigned char header[2] = {(unsigned char)((final ? 0x80 : 0) | opcode),
                             (unsigned char)length};
  return ssl_write_all(ssl, header, sizeof header) &&
         ssl_write_all(ssl, payload, length);
}

static int receive_client_frame(SSL *ssl, unsigned char *opcode,
                                char *payload, size_t capacity, size_t *length) {
  unsigned char header[2];
  if (!ssl_read_exact(ssl, header, sizeof header) || !(header[1] & 0x80)) return 0;
  uint64_t payload_length = header[1] & 0x7f;
  if (payload_length == 126) {
    unsigned char extended[2];
    if (!ssl_read_exact(ssl, extended, sizeof extended)) return 0;
    payload_length = ((uint64_t)extended[0] << 8) | extended[1];
  } else if (payload_length == 127) {
    unsigned char extended[8];
    if (!ssl_read_exact(ssl, extended, sizeof extended)) return 0;
    payload_length = 0;
    for (size_t index = 0; index < sizeof extended; index++)
      payload_length = (payload_length << 8) | extended[index];
  }
  if (payload_length > capacity) return 0;
  unsigned char mask[4];
  if (!ssl_read_exact(ssl, mask, sizeof mask) ||
      !ssl_read_exact(ssl, (unsigned char *)payload, (size_t)payload_length)) return 0;
  for (size_t index = 0; index < payload_length; index++) payload[index] ^= mask[index % 4];
  *opcode = header[0] & 0x0f;
  *length = (size_t)payload_length;
  return 1;
}

static int serve_connection(int listener, enum server_mode mode) {
  SSL_CTX *context = SSL_CTX_new(TLS_server_method());
  if (!context || SSL_CTX_use_certificate_file(context, "/tmp/ws-server.pem", SSL_FILETYPE_PEM) != 1 ||
      SSL_CTX_use_PrivateKey_file(context, "/tmp/ws-server-key.pem", SSL_FILETYPE_PEM) != 1) return 0;
  int peer = accept(listener, NULL, NULL);
  close(listener);
  if (peer < 0) return 0;
  SSL *ssl = SSL_new(context);
  SSL_set_fd(ssl, peer);
  if (SSL_accept(ssl) != 1 || !perform_upgrade(ssl)) {
    SSL_free(ssl);
    close(peer);
    SSL_CTX_free(context);
    /* Rejected client verification intentionally aborts before upgrade. */
    return 1;
  }

  int ok = 1;
  if (mode == HAPPY) {
    unsigned char opcode = 0;
    char payload[256];
    size_t length = 0;
    ok = receive_client_frame(ssl, &opcode, payload, sizeof payload, &length) &&
         opcode == 1 && length == 5 && !memcmp(payload, "hello", 5) &&
         /* Split the UTF-8 snowman between frames. The transport must preserve
          * parser state across both fragments and an interleaved control frame. */
         send_server_frame(ssl, 0, 1, "frag \xe2", 6) &&
         send_server_frame(ssl, 1, 9, "p", 1) &&
         receive_client_frame(ssl, &opcode, payload, sizeof payload, &length) &&
         opcode == 10 && length == 1 && payload[0] == 'p' &&
         send_server_frame(ssl, 1, 0, "\x98\x83 mented", 9) &&
         receive_client_frame(ssl, &opcode, payload, sizeof payload, &length) &&
         opcode == 8;
    if (ok) ok = send_server_frame(ssl, 1, 8, "\x03\xe8", 2);
  } else if (mode == PARTIAL_FRAME) {
    const unsigned char partial[] = {0x81, 0x05, 'p', 'a'};
    ok = ssl_write_all(ssl, partial, sizeof partial);
    struct timespec delay = {.tv_nsec = 500000000};
    nanosleep(&delay, NULL);
  } else {
    struct timespec delay = {.tv_sec = 1};
    nanosleep(&delay, NULL);
  }
  SSL_shutdown(ssl);
  SSL_free(ssl);
  close(peer);
  SSL_CTX_free(context);
  return ok;
}

static int start_server(enum server_mode mode, pid_t *child) {
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) fail("socket failed");
  int yes = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
                                .sin_port = 0};
  if (bind(listener, (struct sockaddr *)&address, sizeof address) || listen(listener, 1))
    fail("listen failed");
  socklen_t address_length = sizeof address;
  if (getsockname(listener, (struct sockaddr *)&address, &address_length)) fail("getsockname failed");
  *child = fork();
  if (*child < 0) fail("fork failed");
  if (!*child) _exit(serve_connection(listener, mode) ? 0 : 1);
  close(listener);
  return ntohs(address.sin_port);
}

static void wait_for_server(pid_t child) {
  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
    fail("fixture server failed");
}

static void test_happy_path(void) {
  pid_t child;
  int port = start_server(HAPPY, &child);
  char url[128];
  snprintf(url, sizeof url, "wss://localhost:%d/live", port);
  void *websocket = c3_ws_connect(url, "/tmp/ws-ca.pem", 1000);
  if (!websocket || !c3_ws_is_active(websocket)) fail("verified connect failed");
  if (!c3_ws_send_text(websocket, "hello", 5, 500)) fail("text send failed");
  char message[64] = {0};
  size_t length = 0;
  if (c3_ws_receive_text(websocket, message, sizeof message, &length, 500) != 1 ||
      length != 15 || memcmp(message, "frag \xe2\x98\x83 mented", 15))
    fail("fragmented text or ping/pong failed");
  if (!c3_ws_close(websocket, 250)) fail("close send failed");
  c3_ws_free(websocket);
  wait_for_server(child);
}

static void test_tls_rejections(void) {
  pid_t child;
  int port = start_server(STALLED, &child);
  char url[128];
  snprintf(url, sizeof url, "wss://127.0.0.1:%d/live", port);
  void *websocket = c3_ws_connect(url, "/tmp/ws-ca.pem", 500);
  if (websocket) fail("hostname mismatch was accepted");
  wait_for_server(child);

  port = start_server(STALLED, &child);
  snprintf(url, sizeof url, "wss://localhost:%d/live", port);
  websocket = c3_ws_connect(url, "/etc/ssl/certs/ca-certificates.crt", 500);
  if (websocket) fail("untrusted peer was accepted");
  wait_for_server(child);
}

static void test_partial_frame_retirement(void) {
  pid_t child;
  int port = start_server(PARTIAL_FRAME, &child);
  char url[128];
  snprintf(url, sizeof url, "wss://localhost:%d/live", port);
  void *websocket = c3_ws_connect(url, "/tmp/ws-ca.pem", 1000);
  if (!websocket) fail("partial-frame connect failed");
  char message[64];
  size_t length = 0;
  if (c3_ws_receive_text(websocket, message, sizeof message, &length, 100) != -1 ||
      c3_ws_is_active(websocket))
    fail("partial-frame timeout did not retire connection");
  if (c3_ws_receive_text(websocket, message, sizeof message, &length, 100) != -1)
    fail("retired connection was reusable");
  c3_ws_free(websocket);
  wait_for_server(child);
}

static void test_idle_timeout_and_bounded_close(void) {
  pid_t child;
  int port = start_server(STALLED, &child);
  char url[128];
  snprintf(url, sizeof url, "wss://localhost:%d/live", port);
  void *websocket = c3_ws_connect(url, "/tmp/ws-ca.pem", 1000);
  if (!websocket) fail("stalled-peer connect failed");
  char message[16];
  size_t length = 0;
  if (c3_ws_receive_text(websocket, message, sizeof message, &length, 75) != 0 ||
      !c3_ws_is_active(websocket))
    fail("idle timeout damaged connection");
  int64_t start = monotonic_millis();
  c3_ws_close(websocket, 100);
  int64_t elapsed = monotonic_millis() - start;
  c3_ws_free(websocket);
  if (elapsed > 300) fail("close exceeded its deadline");
  wait_for_server(child);
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  SSL_library_init();
  test_happy_path();
  test_tls_rejections();
  test_partial_frame_retirement();
  test_idle_timeout_and_bounded_close();
  puts("c3 websocket platform fixture passed");
  return 0;
}
