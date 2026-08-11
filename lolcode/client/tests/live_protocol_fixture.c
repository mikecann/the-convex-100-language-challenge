#define _POSIX_C_SOURCE 200809L

#include <openssl/evp.h>

#include <arpa/inet.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *message)
{
    fprintf(stderr, "LOLCODE Live protocol fixture: %s\n", message);
    exit(1);
}

static int send_all(int fd, const void *data, size_t length)
{
    const unsigned char *bytes = data;
    while (length) {
        ssize_t count = send(fd, bytes, length, 0);
        if (count <= 0) return 0;
        bytes += count;
        length -= (size_t)count;
    }
    return 1;
}

static int receive_exact(int fd, void *data, size_t length)
{
    unsigned char *bytes = data;
    while (length) {
        ssize_t count = recv(fd, bytes, length, 0);
        if (count <= 0) return 0;
        bytes += count;
        length -= (size_t)count;
    }
    return 1;
}

static int websocket_accept_value(const char *request, char output[29])
{
    const char *key = strstr(request, "Sec-WebSocket-Key: ");
    if (!key) return 0;
    key += strlen("Sec-WebSocket-Key: ");
    const char *end = strstr(key, "\r\n");
    if (!end || end - key > 64) return 0;
    char source[128];
    int length = snprintf(source, sizeof source,
        "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", (int)(end - key), key);
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_length = 0;
    EVP_MD_CTX *context = EVP_MD_CTX_new();
    int ok = context && length > 0 && length < (int)sizeof source &&
        EVP_DigestInit_ex(context, EVP_sha1(), NULL) == 1 &&
        EVP_DigestUpdate(context, source, (size_t)length) == 1 &&
        EVP_DigestFinal_ex(context, digest, &digest_length) == 1;
    EVP_MD_CTX_free(context);
    return ok && digest_length == 20 &&
        EVP_EncodeBlock((unsigned char *)output, digest, (int)digest_length) == 28;
}

static int upgrade(int fd)
{
    char request[8192] = {0};
    size_t used = 0;
    while (!strstr(request, "\r\n\r\n") && used < sizeof request - 1) {
        ssize_t count = recv(fd, request + used, sizeof request - used - 1, 0);
        if (count <= 0) return 0;
        used += (size_t)count;
        request[used] = '\0';
    }
    char accept[29] = {0};
    if (!websocket_accept_value(request, accept)) return 0;
    char response[512];
    int length = snprintf(response, sizeof response,
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n", accept);
    return length > 0 && send_all(fd, response, (size_t)length);
}

static int receive_frame(int fd, unsigned char *opcode, char *payload,
                         size_t capacity, size_t *length)
{
    unsigned char header[2];
    if (!receive_exact(fd, header, sizeof header)) return 0;
    if (!(header[1] & 0x80)) return 0;
    uint64_t size = header[1] & 0x7f;
    if (size == 126) {
        unsigned char extended[2];
        if (!receive_exact(fd, extended, sizeof extended)) return 0;
        size = ((uint64_t)extended[0] << 8) | extended[1];
    } else if (size == 127) {
        unsigned char extended[8];
        if (!receive_exact(fd, extended, sizeof extended)) return 0;
        size = 0;
        for (size_t index = 0; index < sizeof extended; index++)
            size = (size << 8) | extended[index];
    }
    if (size >= capacity) return 0;
    unsigned char mask[4];
    if (!receive_exact(fd, mask, sizeof mask) ||
        !receive_exact(fd, payload, (size_t)size)) return 0;
    for (size_t index = 0; index < size; index++) payload[index] ^= mask[index % 4];
    payload[size] = '\0';
    *opcode = header[0] & 0x0f;
    *length = (size_t)size;
    return 1;
}

static int send_text(int fd, const char *payload)
{
    size_t length = strlen(payload);
    unsigned char header[10] = {0x81};
    size_t header_length = 2;
    if (length < 126) {
        header[1] = (unsigned char)length;
    } else if (length <= UINT16_MAX) {
        header[1] = 126;
        header[2] = (unsigned char)(length >> 8);
        header[3] = (unsigned char)length;
        header_length = 4;
    } else {
        return 0;
    }
    return send_all(fd, header, header_length) && send_all(fd, payload, length);
}

static void require_text(int fd, char *payload, size_t capacity)
{
    unsigned char opcode = 0;
    size_t length = 0;
    if (!receive_frame(fd, &opcode, payload, capacity, &length) || opcode != 1 || !length)
        fail("expected client text frame");
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    alarm(30);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons(43142),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof address) ||
        listen(listener, 2)) fail("listen failed");
    FILE *ready = fopen("/tmp/live-server.ready", "w");
    if (!ready || fputs("ready\n", ready) < 0 || fclose(ready))
        fail("readiness signal failed");

    const char *initial =
        "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},"
        "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"BBBBBBBBBBB=\"},"
        "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":0,\"logLines\":[]}]}";
    const char *updated =
        "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"BBBBBBBBBBB=\"},"
        "\"endVersion\":{\"querySet\":1,\"identity\":1,\"ts\":\"CCCCCCCCCCC=\"},"
        "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":1,\"logLines\":[]}]}";

    for (int connection = 0; connection < 6; connection++) {
        fprintf(stderr, "fixture waiting connection %d\n", connection);
        int peer = accept(listener, NULL, NULL);
        if (peer < 0 || !upgrade(peer)) fail("upgrade failed");
        char message[8192];
        require_text(peer, message, sizeof message);
        char expected_count[64];
        snprintf(expected_count, sizeof expected_count, "\"connectionCount\":%d", connection);
        if (!strstr(message, "\"type\":\"Connect\"") || !strstr(message, expected_count) ||
            (connection == 0 && !strstr(message, "\"lastCloseReason\":\"InitialConnect\"")) ||
            (connection > 0 && !strstr(message, "\"lastCloseReason\":\"DebugDisconnect\""))) {
            fprintf(stderr, "unexpected Connect %d: %s\n", connection, message);
            fail("Connect metadata mismatch");
        }
        fprintf(stderr, "fixture got Connect %d\n", connection);
        require_text(peer, message, sizeof message);
        if (!strstr(message, "\"type\":\"ModifyQuerySet\"") ||
            !strstr(message, "\"baseVersion\":0") ||
            !strstr(message, "\"newVersion\":1") ||
            !strstr(message, "\"type\":\"Add\"") ||
            !strstr(message, "\"queryId\":0")) fail("Add replay mismatch");
        fprintf(stderr, "fixture got Add %d\n", connection);
        if (!send_text(peer, initial)) fail("initial transition send failed");
        if (connection < 5) {
            char byte;
            while (recv(peer, &byte, 1, 0) > 0) {}
            fprintf(stderr, "fixture saw disconnect %d\n", connection);
            close(peer);
            continue;
        }
        nanosleep(&(struct timespec){ .tv_nsec = 250000000 }, NULL);
        if (!send_text(peer, updated)) fail("external update send failed");
        require_text(peer, message, sizeof message);
        if (!strstr(message, "\"baseVersion\":1") ||
            !strstr(message, "\"newVersion\":2") ||
            !strstr(message, "\"type\":\"Remove\"") ||
            !strstr(message, "\"queryId\":0")) fail("Remove mismatch");
        fprintf(stderr, "fixture got Remove\n");
        unsigned char opcode = 0;
        size_t length = 0;
        if (!receive_frame(peer, &opcode, message, sizeof message, &length) || opcode != 8)
            fail("bounded close frame missing");
        close(peer);
    }
    close(listener);
    puts("lolcode Live protocol fixture: ok");
    return 0;
}
