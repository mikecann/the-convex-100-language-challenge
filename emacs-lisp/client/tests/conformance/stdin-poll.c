/* stdin-poll.c - the only native code anywhere in this client, and it exists
 * solely for the test-only NDJSON adapter (adapter.el), never for convex.el
 * itself. convex.el's HTTP, TLS, JSON, and hand-rolled WebSocket layers are
 * all pure Emacs Lisp over Emacs's own built-in primitives (url.el,
 * open-network-stream with :type 'tls, json-parse-string, secure-hash), with
 * no C anywhere in that path - matching every other native client in this
 * project's use of the host language's own network primitives.
 *
 * The adapter's own loop has a narrower problem convex.el never faces: it
 * must multiplex two independent readiness conditions - the next NDJSON
 * command arriving on stdin, and the next Live delivery becoming available
 * from the WebSocket convex.el already owns - from a single control flow,
 * with neither one blocking the other indefinitely. Emacs's own network
 * processes support exactly this via accept-process-output with a timeout,
 * but batch-mode Emacs Lisp has no equivalent for its own inherited stdin:
 * read-from-minibuffer (the only primitive that reads piped, non-tty stdin
 * at all in --batch mode) is an uninterruptible blocking read with no
 * timeout, read-event/read-char/sit-for never observe piped stdin data at
 * all even when it is already available, Lisp threads do not run
 * concurrently with a blocking read (one thread blocked on stdin stalls the
 * whole process, confirmed empirically in both directions), and a spawned
 * subprocess does not inherit this process's own external stdin (Emacs
 * redirects a child's stdin to a pipe it controls). This is the same
 * blocking-I/O constraint several other single-threaded languages in this
 * project hit for the identical reason (see cobol/client/convex-native.c,
 * forth/client/convexrt.c, rexx/client/shim.c, icon/client/shim.c), and it
 * is solved here the same way they solve it: a poll(2) readiness check on
 * stdin, callable with a timeout, driven from the adapter's own loop.
 *
 * This program does nothing else. It never reads or forwards any byte of
 * stdin itself - only convex.el's own read-from-minibuffer call ever
 * consumes adapter input - so there is no relay, no second copy of the
 * protocol, and no race over who owns the data.
 *
 * It cannot simply poll its own fd 0: Emacs's `call-process' does not
 * connect a child process's stdin to the fd Emacs itself inherited, only
 * to /dev/null (confirmed empirically - without this, every poll reported
 * "ready" immediately, because reading /dev/null always returns EOF right
 * away). The caller passes its own pid instead, and this program reopens
 * that process's real fd 0 via /proc/PID/fd/0 - a standard Linux mechanism
 * for obtaining a second, independent file descriptor onto the same
 * underlying open file description (regular file or pipe alike) - and
 * polls that.
 *
 * Usage: stdin-poll EMACS_PID TIMEOUT_MS
 * Exit status:
 *   0  stdin has data (or EOF) ready to read right now
 *   1  the timeout elapsed with nothing ready
 *   2  usage, open(2), or poll(2) error
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3) return 2;

  char *end = NULL;
  long pid = strtol(argv[1], &end, 10);
  if (end == NULL || *end != '\0' || pid <= 0) return 2;

  end = NULL;
  long timeout_ms = strtol(argv[2], &end, 10);
  if (end == NULL || *end != '\0' || timeout_ms < 0 || timeout_ms > 60000) {
    return 2;
  }

  char path[64];
  int written = snprintf(path, sizeof(path), "/proc/%ld/fd/0", pid);
  if (written < 0 || (size_t)written >= sizeof(path)) return 2;

  int fd = open(path, O_RDONLY | O_NONBLOCK);
  if (fd < 0) return 2;

  struct pollfd entry;
  entry.fd = fd;
  entry.events = POLLIN;
  entry.revents = 0;

  for (;;) {
    int ready = poll(&entry, 1, (int)timeout_ms);
    if (ready > 0) {
      close(fd);
      return 0;
    }
    if (ready == 0) {
      close(fd);
      return 1;
    }
    if (errno == EINTR) continue;
    close(fd);
    return 2;
  }
}
