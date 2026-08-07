/*
 * Test-only fixture peers for the COBOL Convex client.
 *
 * This file is linked ONLY into test binaries. It is never part of
 * convex-example or convex-adapter, and it grants no capability the
 * client does not already have: it opens loopback sockets and socket
 * pairs in this process, nothing else.
 *
 * Two shapes of peer:
 *
 *   1. A socketpair whose far end is preloaded with exact bytes. The
 *      client reads real socket data through its real code path, and
 *      the test controls precisely how much is available at each
 *      point. No timing is involved, so these cases are perfectly
 *      reproducible.
 *
 *   2. A forked child that binds a loopback port and replays a byte
 *      script. Used only where timing is the subject under test:
 *      dribbling one byte at a time, and stalling mid-message past
 *      the client's deadline.
 *
 * The Live peer additionally speaks enough of RFC 6455 and the Convex
 * sync protocol to complete a handshake, read the client's Connect and
 * ModifyQuerySet frames, and reply with scripted Transitions across
 * several sequential connections.
 */

#define _POSIX_C_SOURCE 200809L

#include "../../convex-native.h"

#include <arpa/inet.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

#include <openssl/sha.h>

#define FIX_MAX_BLOB 262144
#define FIX_BUF 65536

static pid_t g_child = -1;

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static void sleep_ms(int ms)
{
    struct timespec ts;

    if (ms <= 0) {
        return;
    }
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static int write_all(int fd, const unsigned char *buf, int len)
{
    int done = 0;

    while (done < len) {
        int n = (int)write(fd, buf + done, (size_t)(len - done));

        if (n > 0) {
            done += n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

/* COBOL PIC X fields are space padded; trim to the declared length. */
static int copy_len(int len, int cap)
{
    if (len < 0) {
        return 0;
    }
    return len > cap ? cap : len;
}

/* Trim a space padded COBOL field into a C string. */
static int copy_field_local(const char *in, int len, char *out, int cap)
{
    int n = len;

    if (in == NULL || out == NULL || cap <= 0) {
        return -1;
    }
    while (n > 0 && (in[n - 1] == ' ' || in[n - 1] == '\0')) {
        n--;
    }
    if (n <= 0 || n >= cap) {
        return -1;
    }
    memcpy(out, in, (size_t)n);
    out[n] = '\0';
    return n;
}

static const char *B64 =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void base64(const unsigned char *in, int len, char *out)
{
    int i = 0;
    int o = 0;

    while (i < len) {
        int b0 = in[i];
        int b1 = (i + 1 < len) ? in[i + 1] : 0;
        int b2 = (i + 2 < len) ? in[i + 2] : 0;

        out[o++] = B64[b0 >> 2];
        out[o++] = B64[((b0 & 3) << 4) | (b1 >> 4)];
        out[o++] = (i + 1 < len) ? B64[((b1 & 15) << 2) | (b2 >> 6)] : '=';
        out[o++] = (i + 2 < len) ? B64[b2 & 63] : '=';
        i += 3;
    }
    out[o] = '\0';
}

/* ------------------------------------------------------------------ */
/* 1. Socket pair with a preloaded far end                             */
/* ------------------------------------------------------------------ */

/* Create a connected pair. The client end is registered as a normal
 * transport handle, so the code under test cannot tell it apart from a
 * real connection. The peer end is returned as a raw descriptor the
 * test drives directly. */
int cvx_fixture_pair(int *peer_fd, int *handle)
{
    int sv[2];
    int h;

    if (peer_fd == NULL || handle == NULL) {
        return CVX_ERR;
    }
    *peer_fd = -1;
    *handle = -1;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        return CVX_ERR;
    }
    h = cvx_net_register_fd(sv[0]);
    if (h < 0) {
        close(sv[0]);
        close(sv[1]);
        return h;
    }
    *peer_fd = sv[1];
    *handle = h;
    return CVX_OK;
}

/* Make exactly these bytes readable by the client, and no more. */
int cvx_fixture_push(int peer_fd, const unsigned char *bytes, int len)
{
    if (peer_fd < 0 || bytes == NULL || len < 0) {
        return CVX_ERR;
    }
    if (len == 0) {
        return CVX_OK;
    }
    return write_all(peer_fd, bytes, len) == 0 ? CVX_OK : CVX_ERR;
}

/* Read whatever the client wrote, so a test can assert on the request
 * it produced. Never blocks: absent data returns zero bytes. */
int cvx_fixture_drain(int peer_fd, unsigned char *out, int cap, int *got)
{
    int n;

    if (out == NULL || got == NULL || cap <= 0) {
        return CVX_ERR;
    }
    *got = 0;
    if (peer_fd < 0) {
        return CVX_ERR;
    }
    n = (int)recv(peer_fd, out, (size_t)cap, MSG_DONTWAIT);
    if (n > 0) {
        *got = n;
        return CVX_OK;
    }
    if (n == 0) {
        return CVX_EOF;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return CVX_OK;
    }
    return CVX_ERR;
}

/* Half close, so the client observes a clean end of stream. */
int cvx_fixture_shutdown(int peer_fd)
{
    if (peer_fd < 0) {
        return CVX_ERR;
    }
    shutdown(peer_fd, SHUT_WR);
    return CVX_OK;
}

int cvx_fixture_close_peer(int peer_fd)
{
    if (peer_fd < 0) {
        return CVX_ERR;
    }
    close(peer_fd);
    return CVX_OK;
}

/* ------------------------------------------------------------------ */
/* 2. Forked loopback peer replaying a byte script                     */
/* ------------------------------------------------------------------ */

static int bind_loopback(int *port)
{
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    int fd;
    int one = 1;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(fd, 8) != 0 ||
        getsockname(fd, (struct sockaddr *)&addr, &len) != 0) {
        close(fd);
        return -1;
    }
    *port = (int)ntohs(addr.sin_port);
    return fd;
}

/* Replay a blob according to the mode:
 *   0  whole blob at once
 *   1  one byte every delay_ms, to prove the reader reassembles a
 *      message that never arrives in one piece
 *   2  prefix_len bytes, then hold the connection open past the
 *      client's deadline, to prove the client gives up rather than
 *      hanging or restarting its parser at a false boundary */
static void replay(int fd, const unsigned char *blob, int len, int mode,
                   int prefix_len, int delay_ms)
{
    int i;

    switch (mode) {
    case 1:
        for (i = 0; i < len; i++) {
            if (write_all(fd, blob + i, 1) != 0) {
                return;
            }
            sleep_ms(delay_ms);
        }
        break;
    case 2:
        if (prefix_len > len) {
            prefix_len = len;
        }
        if (write_all(fd, blob, prefix_len) != 0) {
            return;
        }
        sleep_ms(delay_ms);
        break;
    default:
        write_all(fd, blob, len);
        break;
    }
}

int cvx_fixture_spawn(const unsigned char *blob, int len, int mode,
                      int prefix_len, int delay_ms, int *port)
{
    unsigned char copy[FIX_MAX_BLOB];
    int listener;
    pid_t pid;

    if (blob == NULL || port == NULL) {
        return CVX_ERR;
    }
    len = copy_len(len, FIX_MAX_BLOB);
    memcpy(copy, blob, (size_t)len);

    listener = bind_loopback(port);
    if (listener < 0) {
        return CVX_ERR;
    }
    pid = fork();
    if (pid < 0) {
        close(listener);
        return CVX_ERR;
    }
    if (pid == 0) {
        int c = accept(listener, NULL, NULL);
        unsigned char scratch[FIX_BUF];

        if (c >= 0) {
            /* Consume the request so the client's write completes. */
            recv(c, scratch, sizeof(scratch), MSG_DONTWAIT);
            replay(c, copy, len, mode, prefix_len, delay_ms);
            if (mode != 2) {
                shutdown(c, SHUT_WR);
                sleep_ms(50);
            }
            close(c);
        }
        close(listener);
        _exit(0);
    }
    close(listener);
    g_child = pid;
    return CVX_OK;
}

/* ------------------------------------------------------------------ */
/* 3. WebSocket and Convex sync peer                                   */
/* ------------------------------------------------------------------ */

/* Read the client's upgrade request and answer it correctly, so the
 * client's own accept-key check passes and the connection reaches the
 * framing layer under test. */
static int do_handshake(int fd)
{
    char req[FIX_BUF];
    int used = 0;
    char *key;
    char *eol;
    char concat[128];
    unsigned char digest[20];
    char accept[64];
    char resp[256];
    int n;

    while (used < (int)sizeof(req) - 1) {
        n = (int)recv(fd, req + used, sizeof(req) - 1 - (size_t)used, 0);
        if (n <= 0) {
            return -1;
        }
        used += n;
        req[used] = '\0';
        if (strstr(req, "\r\n\r\n") != NULL) {
            break;
        }
    }
    req[used] = '\0';

    key = strstr(req, "Sec-WebSocket-Key: ");
    if (key == NULL) {
        return -1;
    }
    key += 19;
    eol = strstr(key, "\r\n");
    if (eol == NULL || (eol - key) > 64) {
        return -1;
    }
    n = (int)(eol - key);
    memcpy(concat, key, (size_t)n);
    memcpy(concat + n, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", 36);
    SHA1((unsigned char *)concat, (size_t)(n + 36), digest);
    base64(digest, 20, accept);

    n = snprintf(resp, sizeof(resp),
                 "HTTP/1.1 101 Switching Protocols\r\n"
                 "Upgrade: websocket\r\n"
                 "Connection: Upgrade\r\n"
                 "Sec-WebSocket-Accept: %s\r\n\r\n",
                 accept);
    return write_all(fd, (unsigned char *)resp, n);
}

/* Build an unmasked server text frame. */
static int server_frame(unsigned char *out, const char *text, int len)
{
    int o = 0;

    out[o++] = 0x81;
    if (len < 126) {
        out[o++] = (unsigned char)len;
    } else {
        out[o++] = 126;
        out[o++] = (unsigned char)((len >> 8) & 0xff);
        out[o++] = (unsigned char)(len & 0xff);
    }
    memcpy(out + o, text, (size_t)len);
    return o + len;
}

/* Read one masked client frame and unmask its payload. Returns the
 * payload length, or -1. Only what the client actually sends is
 * supported: text frames up to 64 KiB. */
static int read_client_frame(int fd, char *out, int cap)
{
    unsigned char hdr[8];
    unsigned char mask[4];
    int len;
    int i;
    int got = 0;

    if (recv(fd, hdr, 2, MSG_WAITALL) != 2) {
        return -1;
    }
    len = hdr[1] & 0x7f;
    if (len == 126) {
        if (recv(fd, hdr, 2, MSG_WAITALL) != 2) {
            return -1;
        }
        len = (hdr[0] << 8) | hdr[1];
    }
    if (len > cap) {
        return -1;
    }
    if (recv(fd, mask, 4, MSG_WAITALL) != 4) {
        return -1;
    }
    while (got < len) {
        int n = (int)recv(fd, out + got, (size_t)(len - got), 0);

        if (n <= 0) {
            return -1;
        }
        got += n;
    }
    for (i = 0; i < len; i++) {
        out[i] = (char)((unsigned char)out[i] ^ mask[i % 4]);
    }
    return len;
}

/* A Live peer that serves `connections` sequential sessions.
 *
 * Session N replies with a Transition whose count is N-1, so a test
 * that forces five reconnects observes five distinct values and can
 * tell a genuine rehydration from a suppressed unchanged one.
 *
 * The child exits with the number of sessions in which the client
 * correctly rebuilt its query set by resending an Add, which is how
 * the parent proves the query-set rebuild actually happened.
 */
int cvx_fixture_spawn_live(int connections, int mode, int *port)
{
    int listener;
    pid_t pid;

    if (port == NULL || connections < 1 || connections > 32) {
        return CVX_ERR;
    }
    listener = bind_loopback(port);
    if (listener < 0) {
        return CVX_ERR;
    }
    pid = fork();
    if (pid < 0) {
        close(listener);
        return CVX_ERR;
    }
    if (pid == 0) {
        int session;
        int rebuilt = 0;

        for (session = 0; session < connections; session++) {
            char msg[FIX_BUF];
            char body[1024];
            unsigned char frame[2048];
            int c = accept(listener, NULL, NULL);
            int n;
            int saw_add = 0;

            if (c < 0) {
                break;
            }
            if (do_handshake(c) != 0) {
                close(c);
                break;
            }
            /* Connect, then ModifyQuerySet. The client must resend its
             * active Add on every fresh connection. */
            n = read_client_frame(c, msg, sizeof(msg) - 1);
            if (n > 0) {
                msg[n] = '\0';
            }
            n = read_client_frame(c, msg, sizeof(msg) - 1);
            if (n > 0) {
                msg[n] = '\0';
                if (strstr(msg, "\"Add\"") != NULL) {
                    saw_add = 1;
                    rebuilt++;
                }
            }
            if (saw_add) {
                /* mode 1 injects a QueryFailed before the good value,
                 * to prove the subscription recovers on the same
                 * connection rather than being stranded. */
                if (mode == 1 && session == 0) {
                    n = snprintf(body, sizeof(body),
                        "{\"type\":\"Transition\",\"startVersion\":"
                        "{\"querySet\":0,\"identity\":0,"
                        "\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":"
                        "{\"querySet\":1,\"identity\":0,"
                        "\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":"
                        "[{\"type\":\"QueryFailed\",\"queryId\":1,"
                        "\"errorMessage\":\"room is empty\","
                        "\"errorData\":{\"code\":\"ROOM_EMPTY\"}}]}");
                    n = server_frame(frame, body, n);
                    write_all(c, frame, n);
                    n = snprintf(body, sizeof(body),
                        "{\"type\":\"Transition\",\"startVersion\":"
                        "{\"querySet\":1,\"identity\":0,"
                        "\"ts\":\"AQAAAAAAAAA=\"},\"endVersion\":"
                        "{\"querySet\":1,\"identity\":0,"
                        "\"ts\":\"AgAAAAAAAAA=\"},\"modifications\":"
                        "[{\"type\":\"QueryUpdated\",\"queryId\":1,"
                        "\"value\":{\"count\":1}}]}");
                    n = server_frame(frame, body, n);
                    write_all(c, frame, n);
                } else {
                    n = snprintf(body, sizeof(body),
                        "{\"type\":\"Transition\",\"startVersion\":"
                        "{\"querySet\":0,\"identity\":0,"
                        "\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":"
                        "{\"querySet\":1,\"identity\":0,"
                        "\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":"
                        "[{\"type\":\"QueryUpdated\",\"queryId\":1,"
                        "\"value\":{\"count\":%d}}]}",
                        session);
                    n = server_frame(frame, body, n);
                    write_all(c, frame, n);
                }
            }
            /* Hold the session open until the client drops it. The
             * reconnect under test is driven by debugDisconnect, not
             * by the peer hanging up. */
            sleep_ms(3000);
            close(c);
        }
        close(listener);
        _exit(rebuilt);
    }
    close(listener);
    g_child = pid;
    return CVX_OK;
}

/* Wait for the fixture child and report its exit status, which the
 * Live peer uses to report how many sessions rebuilt the query set. */
int cvx_fixture_reap(int *exit_code)
{
    int status = 0;

    if (exit_code != NULL) {
        *exit_code = -1;
    }
    if (g_child <= 0) {
        return CVX_ERR;
    }
    if (waitpid(g_child, &status, 0) < 0) {
        g_child = -1;
        return CVX_ERR;
    }
    g_child = -1;
    if (exit_code != NULL && WIFEXITED(status)) {
        *exit_code = WEXITSTATUS(status);
    }
    return CVX_OK;
}

/* Terminate a peer that is deliberately stalling, so a test never
 * leaves a child behind. */
int cvx_fixture_kill(void)
{
    int status = 0;

    if (g_child > 0) {
        kill(g_child, SIGKILL);
        waitpid(g_child, &status, 0);
        g_child = -1;
    }
    return CVX_OK;
}

/* ------------------------------------------------------------------ */
/* 4. Stopped-reader harness for the real adapter binary               */
/* ------------------------------------------------------------------ */

static pid_t g_adapter = -1;

/* Launch the real convex-adapter with its stdout connected to a pipe
 * this process deliberately never reads. That is the whole point: a
 * controller that stops reading must apply backpressure through the
 * kernel rather than causing the adapter to accumulate anything.
 *
 * Returns a writable descriptor for the adapter's stdin. */
int cvx_fixture_spawn_adapter(const char *path, int path_len, int *in_fd)
{
    char exe[512];
    int to_child[2];
    int from_child[2];
    pid_t pid;

    if (in_fd == NULL) {
        return CVX_ERR;
    }
    *in_fd = -1;
    if (copy_field_local(path, path_len, exe, sizeof(exe)) <= 0) {
        return CVX_ERR;
    }
    if (pipe(to_child) != 0) {
        return CVX_ERR;
    }
    if (pipe(from_child) != 0) {
        close(to_child[0]);
        close(to_child[1]);
        return CVX_ERR;
    }
    pid = fork();
    if (pid < 0) {
        close(to_child[0]);
        close(to_child[1]);
        close(from_child[0]);
        close(from_child[1]);
        return CVX_ERR;
    }
    if (pid == 0) {
        dup2(to_child[0], 0);
        dup2(from_child[1], 1);
        close(to_child[0]);
        close(to_child[1]);
        close(from_child[0]);
        close(from_child[1]);
        execl(exe, exe, (char *)NULL);
        _exit(127);
    }
    close(to_child[0]);
    close(from_child[1]);
    /* from_child[0] is intentionally left open and never read, so the
     * pipe fills and stays full. */
    *in_fd = to_child[1];
    g_adapter = pid;
    return CVX_OK;
}

/* Resident set size of the adapter child, in bytes. statm reports
 * pages, so it is scaled here for the same reason cvx_rss_bytes does
 * it: the raw field would understate memory by the page size. */
int cvx_fixture_adapter_rss(long long *out_bytes)
{
    char procpath[64];
    FILE *f;
    long long total = 0;
    long long resident = 0;
    long page;

    if (out_bytes == NULL) {
        return CVX_ERR;
    }
    *out_bytes = 0;
    if (g_adapter <= 0) {
        return CVX_ERR;
    }
    snprintf(procpath, sizeof(procpath), "/proc/%ld/statm", (long)g_adapter);
    f = fopen(procpath, "r");
    if (f == NULL) {
        return CVX_ERR;
    }
    if (fscanf(f, "%lld %lld", &total, &resident) != 2) {
        fclose(f);
        return CVX_ERR;
    }
    fclose(f);
    page = sysconf(_SC_PAGESIZE);
    if (page <= 0) {
        return CVX_ERR;
    }
    *out_bytes = resident * (long long)page;
    return CVX_OK;
}

/* Write to the adapter's stdin without blocking forever: once the
 * adapter is wedged on its own blocked stdout it will stop draining,
 * and the test needs to notice that rather than hang. */
int cvx_fixture_feed_adapter(int in_fd, const unsigned char *buf, int len,
                             int timeout_ms, int *sent)
{
    int done = 0;

    if (sent == NULL || buf == NULL || in_fd < 0) {
        return CVX_ERR;
    }
    *sent = 0;
    while (done < len) {
        struct pollfd pfd;
        int n;

        pfd.fd = in_fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        n = poll(&pfd, 1, timeout_ms);
        if (n <= 0) {
            *sent = done;
            return CVX_TIMEOUT;
        }
        n = (int)write(in_fd, buf + done, (size_t)(len - done));
        if (n > 0) {
            done += n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        *sent = done;
        return CVX_ERR;
    }
    *sent = done;
    return CVX_OK;
}

int cvx_fixture_kill_adapter(void)
{
    int status = 0;

    if (g_adapter > 0) {
        kill(g_adapter, SIGKILL);
        waitpid(g_adapter, &status, 0);
        g_adapter = -1;
    }
    return CVX_OK;
}
