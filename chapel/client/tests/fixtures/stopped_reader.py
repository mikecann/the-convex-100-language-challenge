#!/usr/bin/env python3
"""Hold adapter stdout unread and prove its bounded writer fails closed."""

import json
import http.server
import os
import select
import subprocess
import sys
import time
import threading

LIMIT_KIB = 128 * 1024


def resident_kib(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/status", encoding="ascii") as status:
            for line in status:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except FileNotFoundError:
        pass
    return 0


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: stopped_reader.py FINAL_ADAPTER_BINARY CLOSE_BUDGET_BINARY"
        )
    error_body = json.dumps({
        "status": "error",
        "errorMessage": "x" * (1536 * 1024),
        "logLines": [],
    }).encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            self.wfile.write(error_body)

        def log_message(self, *_args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    environment = dict(os.environ)
    environment["CONVEX_URL"] = f"http://127.0.0.1:{server.server_port}"
    process = subprocess.Popen(
        [sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=environment,
    )
    assert process.stdin is not None
    descriptor = process.stdin.fileno()
    os.set_blocking(descriptor, False)
    hello = (json.dumps({"id": "ready", "op": "hello",
                         "protocolVersion": 1}) + "\n").encode()
    process.stdin.write(hello)
    process.stdin.flush()
    assert process.stdout is not None
    # Same fixture-teardown/startup housekeeping margin used elsewhere in
    # this test suite (see hostile_peer.py): on a loaded/virtualized host,
    # process startup and the first stdio round trip can themselves be
    # delayed well past a couple of seconds. This bounds how long the
    # *controller* waits to observe the adapter's first response, not how
    # fast the adapter is required to answer "hello".
    readable, _, _ = select.select([process.stdout.fileno()], [], [], 20)
    assert readable, "final adapter did not emit ready"
    ready = process.stdout.readline()
    assert b'"id":"ready","type":"ready"' in ready, ready

    # The controller now deliberately stops reading final-adapter stdout. Each
    # valid query produces a near-2 MiB result envelope from the local peer.
    payload = (json.dumps({"id": "x" * 128, "op": "query",
                           "path": "fixture:large", "args": {}}) +
               "\n").encode()
    pending = memoryview(payload)
    sent = 0
    writer_started = 0.0
    peak_kib = 0
    deadline = time.monotonic() + 10
    while process.poll() is None and time.monotonic() < deadline and not sent:
        peak_kib = max(peak_kib, resident_kib(process.pid))
        _, writable, _ = select.select([], [descriptor], [], 0.05)
        if not writable:
            continue
        try:
            count = os.write(descriptor, pending)
        except BrokenPipeError:
            break
        pending = pending[count:]
        if not pending:
            sent = 1
            writer_started = time.monotonic()
    # One queued record cannot trigger the 16-record/8 MiB queue bound. Exit
    # must therefore come from the sole writer's 250 ms write deadline.
    while process.poll() is None and time.monotonic() < deadline:
        peak_kib = max(peak_kib, resident_kib(process.pid))
        time.sleep(0.01)
    assert process.poll() is not None, (
        "stopped-reader adapter did not terminate while stdin remained open"
    )
    try:
        process.stdin.close()
    except BrokenPipeError:
        pass
    try:
        returncode = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        raise AssertionError("stopped-reader adapter did not fail closed")
    stderr = process.stderr.read() if process.stderr else b""
    assert returncode != 0, (returncode, stderr.decode(errors="replace"))
    assert b'"type":"error"' in stderr, stderr
    assert sent > 0
    writer_elapsed = time.monotonic() - writer_started
    assert 0.20 <= writer_elapsed < 1.0, writer_elapsed
    assert peak_kib < LIMIT_KIB, f"adapter RSS reached {peak_kib} KiB"
    server.shutdown()
    server.server_close()
    close_budget = subprocess.Popen(
        [sys.argv[2]], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    close_budget_started = time.monotonic()
    close_budget_returncode = close_budget.wait(timeout=4)
    close_budget_elapsed = time.monotonic() - close_budget_started
    close_budget_stderr = (
        close_budget.stderr.read() if close_budget.stderr else b""
    )
    assert close_budget_returncode == 0, close_budget_stderr.decode(
        errors="replace"
    )
    assert close_budget_elapsed < 3.5, close_budget_elapsed
    print(f"chapel stopped-reader probe passed at {peak_kib} KiB")


if __name__ == "__main__":
    main()
