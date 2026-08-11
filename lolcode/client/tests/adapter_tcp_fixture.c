#define _POSIX_C_SOURCE 200112L

#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int main(void)
{
    struct addrinfo hints = {0}, *result = NULL;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo("127.0.0.1", "43123", &hints, &result)) return 1;
    int fd = -1;
    for (int attempt = 0; attempt < 100; attempt++) {
        fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
        if (fd >= 0 && !connect(fd, result->ai_addr, result->ai_addrlen)) break;
        if (fd >= 0) close(fd);
        fd = -1;
        nanosleep(&(struct timespec){ .tv_nsec = 10000000 }, NULL);
    }
    freeaddrinfo(result);
    if (fd < 0) return 2;

    // Both commands deliberately share one write. The owner must not strand
    // close in stdio read-ahead while polling the underlying descriptor.
    const char *commands =
        "{\"protocolVersion\":1,\"id\":\"tcp-1\",\"op\":\"hello\"}\n"
        "{\"id\":\"tcp-close\",\"op\":\"close\"}\n";
    if (write(fd, commands, strlen(commands)) != (ssize_t)strlen(commands)) return 3;
    char reply[2048] = {0};
    size_t used = 0;
    ssize_t count;
    while ((count = read(fd, reply + used, sizeof reply - used - 1)) > 0) {
        used += (size_t)count;
        if (used == sizeof reply - 1) break;
    }
    close(fd);
    if (!strstr(reply, "\"id\":\"tcp-1\"") ||
        !strstr(reply, "\"type\":\"ready\"") ||
        !strstr(reply, "\"id\":\"tcp-close\"") ||
        !strstr(reply, "\"type\":\"closed\"")) return 4;
    puts("lolcode adapter TCP fixture: ok");
    return 0;
}
