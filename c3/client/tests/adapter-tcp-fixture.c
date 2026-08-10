#define _POSIX_C_SOURCE 200112L
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int main(void) {
  struct addrinfo hints = {0}, *result = NULL;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo("127.0.0.1", "43123", &hints, &result)) return 1;
  int fd = -1;
  for (int attempt = 0; attempt < 100; attempt++) {
    fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (fd >= 0 && !connect(fd, result->ai_addr, result->ai_addrlen)) break;
    if (fd >= 0) close(fd);
    fd = -1;
    nanosleep(&(struct timespec){.tv_nsec = 10000000}, NULL);
  }
  if (fd < 0) return 1;
  freeaddrinfo(result);
  const char *hello = "{\"protocolVersion\":1,\"id\":\"tcp-1\",\"op\":\"hello\"}\n";
  if (write(fd, hello, strlen(hello)) != (ssize_t)strlen(hello)) return 1;
  char reply[512] = {0};
  ssize_t n = read(fd, reply, sizeof reply - 1);
  close(fd);
  return n > 0 && strstr(reply, "\"id\":\"tcp-1\"") && strstr(reply, "\"type\":\"ready\"") ? 0 : 1;
}
