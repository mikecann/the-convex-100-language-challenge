#include <arpa/inet.h>
#include <curl/curl.h>
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *message) {
  fprintf(stderr, "%s\n", message);
  exit(1);
}

static void write_all(int fd, const void *data, size_t size) {
  const unsigned char *bytes = data;
  while(size) {
    ssize_t written = write(fd, bytes, size);
    if(written <= 0)
      fail("fixture write failed");
    bytes += written;
    size -= (size_t)written;
  }
}

static void serve_once(int listener, int partial_successor) {
  int peer = accept(listener, NULL, NULL);
  if(peer < 0)
    fail("fixture accept failed");
  char request[16384] = {0};
  size_t used = 0;
  while(used + 1 < sizeof(request) && !strstr(request, "\r\n\r\n")) {
    ssize_t count = read(peer, request + used, sizeof(request) - used - 1);
    if(count <= 0)
      fail("fixture request read failed");
    used += (size_t)count;
    request[used] = '\0';
  }
  const char *prefix = "Sec-WebSocket-Key: ";
  char *key = strstr(request, prefix);
  if(!key)
    fail("fixture request omitted websocket key");
  key += strlen(prefix);
  char *key_end = strstr(key, "\r\n");
  if(!key_end)
    fail("fixture websocket key was malformed");
  char material[256];
  int material_size = snprintf(
      material, sizeof(material), "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
      (int)(key_end - key), key);
  if(material_size <= 0 || (size_t)material_size >= sizeof(material))
    fail("fixture websocket key was too large");
  unsigned char digest[SHA_DIGEST_LENGTH];
  SHA1((const unsigned char *)material, (size_t)material_size, digest);
  unsigned char accept[64];
  int accept_size = EVP_EncodeBlock(accept, digest, SHA_DIGEST_LENGTH);
  char response[512];
  int response_size = snprintf(
      response, sizeof(response),
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\nConnection: Upgrade\r\n"
      "Sec-WebSocket-Accept: %.*s\r\n\r\n",
      accept_size, accept);
  write_all(peer, response, (size_t)response_size);
  const unsigned char complete[] = {0x81, 0x02, '{', '}'};
  write_all(peer, complete, sizeof(complete));
  if(partial_successor) {
    /* One byte of a new frame header -- not a complete header plus a
     * partial payload. curl's decoder (lib/ws.c, ws_dec_pass) only returns
     * CURLE_AGAIN from curl_ws_recv() while it has delivered zero payload
     * bytes to the caller; the instant it can hand over even one payload
     * byte it returns CURLE_OK with a short read and bytesleft > 0
     * (ws_dec_pass_payload sets ctx.written as soon as it copies anything,
     * and curl_ws_recv only breaks out with CURLE_AGAIN when !ctx.written).
     * A full header ({0x81, 0x02}) plus one payload byte therefore comes
     * back as CURLE_OK, not CURLE_AGAIN -- the odin client already handles
     * exactly that case via `meta.bytesleft != 0` in convex.odin, without
     * needing curl_ws_meta() at all. The scenario curl_ws_meta() actually
     * needs to distinguish is a socket that is genuinely idle from one
     * where a *header* is stuck mid-parse (ws->dec.state has left
     * WS_DEC_INIT but no payload byte has been produced yet), which is
     * what a single, incomplete header byte reproduces. */
    const unsigned char partial[] = {0x81};
    write_all(peer, partial, sizeof(partial));
  }
  sleep(3);
  close(peer);
  close(listener);
  _exit(0);
}

static void run_case(int partial_successor) {
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if(listener < 0)
    fail("fixture socket failed");
  int reuse = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  struct sockaddr_in address = {.sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
                                .sin_port = 0};
  if(bind(listener, (struct sockaddr *)&address, sizeof(address)) ||
     listen(listener, 1))
    fail("fixture listen failed");
  socklen_t address_size = sizeof(address);
  if(getsockname(listener, (struct sockaddr *)&address, &address_size))
    fail("fixture address failed");
  pid_t child = fork();
  if(child < 0)
    fail("fixture fork failed");
  if(child == 0)
    serve_once(listener, partial_successor);

  char url[128];
  snprintf(url, sizeof(url), "ws://127.0.0.1:%u/", ntohs(address.sin_port));
  CURL *easy = curl_easy_init();
  if(!easy)
    fail("curl easy init failed");
  curl_easy_setopt(easy, CURLOPT_URL, url);
  curl_easy_setopt(easy, CURLOPT_CONNECT_ONLY, 2L);
  curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, 2000L);
  if(curl_easy_perform(easy) != CURLE_OK)
    fail("websocket upgrade failed");
  unsigned char buffer[32];
  size_t received = 0;
  const struct curl_ws_frame *meta = NULL;
  if(curl_ws_recv(easy, buffer, sizeof(buffer), &received, &meta) != CURLE_OK ||
     received != 2 || !meta || meta->bytesleft != 0)
    fail("complete websocket frame was not received");
  CURLcode next = curl_ws_recv(easy, buffer, sizeof(buffer), &received, &meta);
  if(next != CURLE_AGAIN)
    fail("incomplete or idle successor did not return CURLE_AGAIN");
  int pending = curl_ws_meta(easy) != NULL;
  if(pending != partial_successor)
    fail("pending decoder state did not distinguish partial input from idle");
  curl_easy_cleanup(easy);
  close(listener);
  kill(child, SIGTERM);
  int status = 0;
  waitpid(child, &status, 0);
}

int main(void) {
  if(curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK)
    fail("curl global init failed");
  run_case(0);
  run_case(1);
  curl_global_cleanup();
  return 0;
}
