#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int receive_request(int fd, char *buffer, size_t capacity)
{
    size_t length = 0;
    size_t target = 0;
    while (length + 1 < capacity) {
        ssize_t count = recv(fd, buffer + length, capacity - length - 1, 0);
        if (count <= 0) return 0;
        length += (size_t)count;
        buffer[length] = '\0';
        char *body = strstr(buffer, "\r\n\r\n");
        if (body && !target) {
            char *content_length = strstr(buffer, "Content-Length:");
            if (!content_length) return 0;
            target = (size_t)(body + 4 - buffer) + strtoul(content_length + 15, NULL, 10);
        }
        if (target && length >= target) return 1;
    }
    return 0;
}

static int send_all(int fd, const char *data, size_t length)
{
    while (length) {
        ssize_t count = send(fd, data, length, 0);
        if (count <= 0) return 0;
        data += count;
        length -= (size_t)count;
    }
    return 1;
}

int main(void)
{
    // Never leave a Docker build waiting forever if the client fails before it
    // connects. The fixture is test infrastructure, not production transport.
    alarm(15);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(43140) };
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof address) < 0 ||
        listen(listener, 4) < 0) return 1;

    for (int request_number = 0; request_number < 3; request_number++) {
        int client = accept(listener, NULL, NULL);
        char request[16384];
        if (client < 0 || !receive_request(client, request, sizeof request)) return 2;
        if (!strstr(request, "POST /api/") || !strstr(request, "Content-Type: application/json") ||
            !strstr(request, "Convex-Client: lolcode-0.1.0")) return 3;

        const char *body;
        if (strstr(request, "counter:get")) {
            if (!strstr(request, "\"args\":{}") || !strstr(request, "\"format\":\"json\"")) return 4;
            body = "{\"status\":\"success\",\"value\":0.0,\"logLines\":[\"HAI\"]}";
        } else if (strstr(request, "counter:fail")) {
            body = "{\"status\":\"error\",\"errorMessage\":\"fixture failed\",\"errorData\":{\"code\":7},\"logLines\":[]}";
        } else {
            body = "{\"status\":\"success\"}";
        }
        char response[2048];
        int length = snprintf(response, sizeof response,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
            strlen(body), body);
        if (length < 0 || !send_all(client, response, (size_t)length)) return 5;
        close(client);
    }
    close(listener);
    return 0;
}
