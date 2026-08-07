#!/usr/bin/env python3
"""Deterministic raw HTTP/TLS/RFC6455 peer for the Chapel client."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LIMIT = 2 * 1024 * 1024


def recv_exact(conn: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = conn.recv(length - len(result))
        if not chunk:
            raise EOFError("connection ended inside a frame")
        result.extend(chunk)
    return bytes(result)


def read_headers(conn: socket.socket) -> tuple[str, dict[str, str], bytes]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise EOFError("request ended before headers")
        data.extend(chunk)
        if len(data) > 32768:
            raise AssertionError("request headers exceeded 32 KiB")
    head, body = bytes(data).split(b"\r\n\r\n", 1)
    lines = head.decode("ascii").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, value = line.split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    while len(body) < length:
        body += conn.recv(length - len(body))
    return lines[0], headers, body[:length]


def response(conn: socket.socket, body: bytes, *, chunked: bool = False,
             status: bytes = b"200 OK") -> None:
    if chunked:
        conn.sendall(
            b"HTTP/1.1 " + status + b"\r\nContent-Type: application/json\r\n"
            b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        )
        for split in (body[:7], body[7:19], body[19:]):
            conn.sendall(f"{len(split):x}\r\n".encode() + split + b"\r\n")
        conn.sendall(b"0\r\n\r\n")
    else:
        conn.sendall(
            b"HTTP/1.1 " + status + b"\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            + body
        )


def read_frame(conn: socket.socket) -> tuple[int, bool, bytes]:
    first, second = recv_exact(conn, 2)
    final = bool(first & 0x80)
    opcode = first & 0x0F
    assert second & 0x80, "client frames must be masked"
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(conn, 8))[0]
    mask = recv_exact(conn, 4)
    payload = bytearray(recv_exact(conn, length))
    for index in range(length):
        payload[index] ^= mask[index % 4]
    return opcode, final, bytes(payload)


def read_text(conn: socket.socket) -> dict:
    message = bytearray()
    while True:
        opcode, final, payload = read_frame(conn)
        if opcode == 8:
            raise EOFError("client closed")
        if opcode in (1, 0):
            message.extend(payload)
            if final:
                return json.loads(message)


def send_frame(conn: socket.socket, opcode: int, payload: bytes,
               *, final: bool = True) -> None:
    conn.sendall(frame_bytes(opcode, payload, final=final))


def frame_bytes(opcode: int, payload: bytes, *, final: bool = True) -> bytes:
    header = bytearray([(0x80 if final else 0) | opcode])
    if len(payload) < 126:
        header.append(len(payload))
    elif len(payload) <= 65535:
        header.append(126)
        header.extend(struct.pack("!H", len(payload)))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", len(payload)))
    return bytes(header + payload)


def timestamp(value: int) -> str:
    return base64.b64encode(struct.pack("<Q", value)).decode()


def transition(query_id: int, start_query_set: int, end_query_set: int,
               start_ts: int, end_ts: int, modification: dict) -> bytes:
    return json.dumps({
        "type": "Transition",
        "startVersion": {
            "querySet": start_query_set, "identity": 0,
            "ts": timestamp(start_ts),
        },
        "endVersion": {
            "querySet": end_query_set, "identity": 0,
            "ts": timestamp(end_ts),
        },
        "modifications": [{"queryId": query_id, **modification}],
    }, ensure_ascii=False, separators=(",", ":")).encode()


class Fixture:
    def __init__(self) -> None:
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.port = self.listener.getsockname()[1]
        self.ws_index = 0
        self.lock = threading.Lock()
        self.failures: list[BaseException] = []
        self.auth_headers: list[str | None] = []
        self.retired = [threading.Event() for _ in range(12)]
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self) -> None:
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(5)
            line, headers, body = read_headers(conn)
            assert line.startswith("POST ") or line.startswith("GET ")
            if headers.get("upgrade", "").lower() == "websocket":
                self.websocket(conn, headers)
            else:
                self.http(conn, headers, body)
        except (BrokenPipeError, ConnectionResetError, EOFError, OSError):
            pass
        except BaseException as error:  # surfaced to the controller thread
            self.failures.append(AssertionError(
                f"{error!r}\n{traceback.format_exc()}"
            ))
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def http(self, conn: socket.socket, headers: dict[str, str],
             body: bytes) -> None:
        assert headers.get("content-type") == "application/json"
        assert headers.get("convex-client") == "chapel-0.1.0"
        command = json.loads(body)
        mode = command["args"]["case"]
        assert command["path"] == "fixture:http"
        if mode == "bounded":
            response(conn, b'{"status":"success","value":{"count":1}}')
        elif mode == "chunked":
            response(conn, b'{"status":"success","value":{"count":2}}',
                     chunked=True)
        elif mode == "oversized":
            response(conn, b"x" * (LIMIT + 1))
        elif mode == "dribbled_status":
            conn.sendall(b"HTTP/1.1 2")
            time.sleep(0.35)
        elif mode == "malformed_envelope":
            response(conn, b'{"status":"success","logLines":[]}')
        elif mode == "invalid_logs":
            response(conn, b'{"status":"success","value":{},"logLines":[1]}')
        elif mode == "non_2xx":
            response(conn, b'{"status":"success","value":{"count":99}}',
                     status=b"503 Service Unavailable")
        elif mode == "missing_error_message":
            response(conn, b'{"status":"error","logLines":[]}')
        elif mode == "wrong_error_message":
            response(conn, b'{"status":"error","errorMessage":7,"logLines":[]}')
        elif mode == "invalid_utf8":
            response(conn, b'{"status":"success","value":"\xff"}')
        elif mode in ("auth_first", "auth_replaced", "auth_empty"):
            self.auth_headers.append(headers.get("authorization"))
            response(conn, b'{"status":"success","value":{"count":4}}')
        elif mode == "recovery":
            response(conn, b'{"status":"success","value":{"count":3}}')
        else:
            raise AssertionError(f"unknown HTTP fixture mode {mode}")

    def handshake(self, conn: socket.socket, headers: dict[str, str],
                  mode: str) -> bool:
        key = headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest())
        if mode == "status":
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            return False
        upgrade = b"WebSocket" if mode != "token" else b"not-websocket"
        if mode == "accept":
            accept = b"invalid"
        conn.sendall(
            b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: " + upgrade +
            b"\r\nConnection: keep-alive, UpGrAdE\r\nSec-WebSocket-Accept: " +
            accept + b"\r\n\r\n"
        )
        valid = mode not in ("token", "accept")
        if not valid:
            # A rejected 101 must not leak a Convex Connect or Add message.
            conn.settimeout(0.2)
            try:
                assert conn.recv(4096) == b""
            except socket.timeout:
                pass
        return valid

    def websocket(self, conn: socket.socket, headers: dict[str, str]) -> None:
        with self.lock:
            index = self.ws_index
            self.ws_index += 1
        assert "upgrade" in headers.get("connection", "").lower()
        assert headers.get("convex-client") == "chapel-0.1.0"
        pre_add_modes = ["status", "token", "accept", "oversize", "partial",
                         "utf8", "ping_flood"]
        if index < len(pre_add_modes):
            mode = pre_add_modes[index]
        elif index == len(pre_add_modes):
            mode = "header_only"
        else:
            mode = "valid"
        if not self.handshake(conn, headers, mode):
            return
        if mode == "oversize":
            send_frame(conn, 1, b"x" * (LIMIT + 1))
            return
        if mode == "partial":
            started = time.monotonic()
            conn.sendall(b"\x81\x7d" + b'{"type":')
            time.sleep(1.25)
            # A loaded/virtualized host can delay this process's own view
            # of socket readiness by several seconds (observed on this
            # shared, contended host: over 1.8s in one run, over 8s in a
            # more heavily loaded run, and over 15s in a still more
            # heavily loaded run, always well after the client had already
            # abandoned the connection). This settimeout, and the
            # assertion below, only bound how long the *fixture* waits to
            # observe that close before complaining -- fixture-side
            # teardown housekeeping, not the client behavior under test
            # (which is exercised by the 1.25s stall above) -- so they
            # carry a generous absolute margin, well under the harness's
            # overall 90s subprocess budget, rather than racing the
            # scheduler. Do not tighten this back down without
            # re-measuring on an idle host.
            conn.settimeout(23.75)
            try:
                while conn.recv(4096):
                    pass
            except socket.timeout as error:
                raise AssertionError("partial-frame connection was not retired") from error
            assert time.monotonic() - started < 25
            return
        if mode == "utf8":
            send_frame(conn, 1, b'{"type":"\xff"}')
            return

        if mode == "ping_flood":
            started = time.monotonic()
            for _ in range(100):
                send_frame(conn, 9, b"p")
                time.sleep(0.001)
            send_frame(conn, 1, b'{"type":"\xff"}')
            # Same fixture-teardown housekeeping margin as the "partial"
            # round above, for the same reason: this bounds how long the
            # fixture waits to observe the client's close, not how quickly
            # the client actually abandoned the connection.
            conn.settimeout(24.9)
            try:
                while conn.recv(4096):
                    pass
            except socket.timeout as error:
                raise AssertionError("ping-flood connection was not retired") from error
            assert time.monotonic() - started < 25
            return

        connect = read_text(conn)
        add = read_text(conn)
        if mode == "header_only":
            assert connect["connectionCount"] == 4
            assert add["baseVersion"] == 0 and add["newVersion"] == 1
            assert add["modifications"][0]["type"] == "Add"
            started = time.monotonic()
            # Connect and Add have both been read above. One frame-header byte
            # then exercises libcurl's header-only internal receive stall.
            conn.sendall(b"\x81")
            conn.settimeout(1.6)
            while conn.recv(4096):
                pass
            elapsed = time.monotonic() - started
            assert 0.85 <= elapsed < 1.5, elapsed
            return

        round_number = index - len(pre_add_modes) - 1
        # The three malformed upgrades are rejected before a chapel_ws exists.
        # Four accepted hostile payload sockets plus the header-only socket are
        # retired before the first valid Convex connection.
        expected_connections = index - 3
        assert connect["connectionCount"] == expected_connections, (
            f"attempt {index} connectionCount={connect['connectionCount']}, "
            f"expected {expected_connections}"
        )
        if round_number > 0:
            assert connect["maxObservedTimestamp"] == timestamp(round_number)
            # Same fixture-teardown housekeeping margin as the "partial"
            # and "ping_flood" rounds above: a loaded/virtualized host can
            # delay this process's own view of the old TCP connection's
            # retirement by seconds, independent of how quickly the client
            # actually retired it, so this waits well under the harness's
            # overall 30s subprocess budget rather than racing the
            # scheduler.
            assert self.retired[round_number - 1].wait(25), (
                "new WebSocket became active before the old TCP retired"
            )
        assert add["baseVersion"] == 0 and add["newVersion"] == 1
        query_id = add["modifications"][0]["queryId"]
        previous = max(0, round_number - 1)
        hydration_ts = max(1, round_number)
        hydration = transition(query_id, 0, 1, 0, hydration_ts, {
            "type": "QueryUpdated",
            "value": {"count": previous, "label": "café"},
            "logLines": [],
        })
        if round_number == 0:
            split = hydration.index("é".encode()) + 1
            send_frame(conn, 1, hydration[:split], final=False)
            time.sleep(0.04)  # exceed one 25 ms receive poll with partial UTF-8
            send_frame(conn, 9, b"probe")
            time.sleep(0.04)  # control interleave must preserve partial text
            send_frame(conn, 0, hydration[split:])
        elif round_number == 1:
            fresh = transition(
                query_id, 1, 1, hydration_ts, round_number + 1, {
                "type": "QueryUpdated",
                "value": {"count": round_number, "label": "café"},
                "logLines": [],
                })
            # Two complete frames in one TCP write exercise buffered decoder
            # state without waiting for another OS readability edge.
            conn.sendall(frame_bytes(1, hydration) + frame_bytes(1, fresh))
        elif round_number == 2:
            fresh = transition(
                query_id, 1, 1, hydration_ts, round_number + 1, {
                "type": "QueryUpdated",
                "value": {"count": round_number, "label": "café"},
                "logLines": [],
                })
            encoded_fresh = frame_bytes(1, fresh)
            # A complete frame followed by one byte of the next header is the
            # internal-buffer variant of the header-only watchdog regression.
            conn.sendall(frame_bytes(1, hydration) + encoded_fresh[:1])
            time.sleep(0.2)
            conn.sendall(encoded_fresh[1:])
        else:
            send_frame(conn, 1, hydration)
            fresh = transition(
                query_id, 1, 1, hydration_ts, round_number + 1, {
                "type": "QueryUpdated",
                "value": {"count": round_number, "label": "café"},
                "logLines": [],
                })
            # Several 25 ms receive timeouts must leave no stale watchdog that
            # can later close this otherwise healthy connection.
            time.sleep(0.25 if round_number == 3 else 0.08)
            send_frame(conn, 1, fresh)
        if round_number == 5:
            send_frame(conn, 1, transition(query_id, 1, 1, 6, 7, {
                "type": "QueryFailed", "errorMessage": "fixture query failed",
                "errorData": {"code": "FIXTURE"}, "logLines": ["failed"],
            }))
            send_frame(conn, 1, transition(query_id, 1, 1, 7, 8, {
                "type": "QueryUpdated", "value": {"count": 6},
                "logLines": [],
            }))
            # Do not read or answer the client's closing handshake. The client
            # must still apply one cumulative close deadline and retire TCP.
            time.sleep(1.0)
        try:
            while conn.recv(4096):
                pass
        finally:
            self.retired[round_number].set()

    def close(self) -> None:
        self.listener.close()
        if self.failures:
            raise self.failures[0]
        # Same fixture-teardown housekeeping margin as the rounds above.
        assert self.retired[5].wait(25), "final Live TCP connection was not retired"
        assert self.ws_index == 14, f"expected 14 WebSocket attempts, got {self.ws_index}"
        assert self.auth_headers == [
            "Bearer opaque-ONE_~!$&'*+.^`|",
            "Bearer replacement-TWO",
            None,
        ], self.auth_headers


def make_tls_listener(directory: str) -> tuple[socket.socket, int]:
    key = os.path.join(directory, "key.pem")
    cert = os.path.join(directory, "cert.pem")
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-days", "1", "-subj", "/CN=127.0.0.1",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", key,
        "-out", cert,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)

    def serve() -> None:
        conn, _ = listener.accept()
        try:
            with context.wrap_socket(conn, server_side=True) as tls:
                read_headers(tls)
                response(tls, b'{"status":"success","value":{"count":9}}')
        except ssl.SSLError:
            pass

    threading.Thread(target=serve, daemon=True).start()
    return listener, listener.getsockname()[1]


def make_slow_ws_listener() -> tuple[socket.socket, int]:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()

    def serve() -> None:
        conn, _ = listener.accept()
        try:
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            _, headers, _ = read_headers(conn)
            key = headers["sec-websocket-key"]
            accept = base64.b64encode(
                hashlib.sha1((key + GUID).encode()).digest())
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and conn.recv(1):
                time.sleep(0.002)
        except (OSError, EOFError):
            pass
        finally:
            conn.close()

    threading.Thread(target=serve, daemon=True).start()
    return listener, listener.getsockname()[1]


def make_short_write_ws_listener() -> tuple[
        socket.socket, int, list[BaseException], threading.Event]:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    failures: list[BaseException] = []
    done = threading.Event()

    def receive_slowly(conn: socket.socket, length: int) -> bytes:
        result = bytearray()
        while len(result) < length:
            chunk = conn.recv(min(4096, length - len(result)))
            if not chunk:
                raise EOFError("connection ended inside short-write frame")
            result.extend(chunk)
            time.sleep(0.0005)
        return bytes(result)

    def serve() -> None:
        conn, _ = listener.accept()
        try:
            conn.settimeout(8)
            # 64 KiB keeps the 8 MiB payload two orders of magnitude larger
            # than one window, so the sender still has to complete 100+
            # partial writes and fully exercise the short-write retry loop.
            # A 1 KiB window (as used by the sibling "slow peer" fixture
            # below, which deliberately never finishes) instead collapses
            # to one receive-window refill per delayed-ACK interval under a
            # virtualized loopback network stack -- around 70ms per ~1 KiB
            # here -- which turns an intentionally-finite drain into one
            # that takes on the order of minutes. That is an artifact of
            # this parameterization, not of the client under test, so do
            # not tighten this back toward 1 KiB without re-measuring the
            # actual wall-clock margin in the target environment first.
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
            _, headers, _ = read_headers(conn)
            key = headers["sec-websocket-key"]
            accept = base64.b64encode(
                hashlib.sha1((key + GUID).encode()).digest())
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")

            first, second = recv_exact(conn, 2)
            assert first == 0x81, f"expected one final text frame, got {first:#x}"
            assert second & 0x80, "client frame was not masked"
            length = second & 0x7f
            if length == 126:
                length = struct.unpack("!H", recv_exact(conn, 2))[0]
            elif length == 127:
                length = struct.unpack("!Q", recv_exact(conn, 8))[0]
            mask = recv_exact(conn, 4)
            payload = bytearray(receive_slowly(conn, length))
            for index in range(length):
                payload[index] ^= mask[index % 4]
            prefix = b"short-write:"
            assert payload.startswith(prefix)
            assert len(payload) == len(prefix) + 8 * 1024 * 1024
            assert payload[len(prefix):] == b"x" * (8 * 1024 * 1024)
            send_frame(conn, 1, b'{"exact":true}')
        except BaseException as error:
            failures.append(AssertionError(
                f"{error!r}\n{traceback.format_exc()}"
            ))
        finally:
            done.set()
            conn.close()

    threading.Thread(target=serve, daemon=True).start()
    return listener, listener.getsockname()[1], failures, done


def main() -> None:
    if len(sys.argv) not in (2, 4):
        raise SystemExit(
            "usage: hostile_peer.py FIXTURE_TEST_BINARY [FINAL_ADAPTER FINAL_EXAMPLE]")
    fixture = Fixture()
    with tempfile.TemporaryDirectory() as directory:
        tls, tls_port = make_tls_listener(directory)
        slow_ws, slow_ws_port = make_slow_ws_listener()
        short_ws, short_ws_port, short_failures, short_done = (
            make_short_write_ws_listener()
        )
        close_error = None
        try:
            environment = dict(os.environ)
            environment["SSL_CERT_FILE"] = os.path.join(directory, "cert.pem")
            # This subprocess walks every HTTP, TLS, slow-peer, short-write,
            # and Live-reconnect round below, several of which now carry
            # their own generous (up to 25s) fixture-teardown margins for
            # a loaded/virtualized host. 150s keeps ample headroom above
            # their sum without being open-ended.
            completed = subprocess.run([
                sys.argv[1], f"http://127.0.0.1:{fixture.port}",
                f"https://localhost:{tls_port}",
                f"ws://127.0.0.1:{slow_ws_port}",
                f"ws://127.0.0.1:{short_ws_port}",
            ], timeout=150, check=False, text=True, capture_output=True,
                env=environment)
        finally:
            tls.close()
            slow_ws.close()
            short_ws.close()
            if not short_done.wait(1):
                close_error = AssertionError(
                    "short-write WebSocket peer did not complete"
                )
            elif short_failures:
                close_error = short_failures[0]
            try:
                fixture.close()
            except BaseException as error:
                if close_error is None:
                    close_error = error
        if len(sys.argv) == 4:
            adapter_tls, adapter_tls_port = make_tls_listener(directory)
            adapter_environment = dict(environment)
            adapter_environment["CONVEX_URL"] = (
                f"https://localhost:{adapter_tls_port}")
            adapter = subprocess.run(
                [sys.argv[2]], input=(
                    '{"id":"tls","op":"query","path":"fixture:http",'
                    '"args":{"case":"tls"}}\n'
                    '{"id":"close","op":"close"}\n'),
                timeout=5, text=True, capture_output=True,
                env=adapter_environment, check=False)
            adapter_tls.close()
            assert adapter.returncode == 0, adapter.stderr
            assert '"id":"tls","type":"result","value":{"count":9}' in adapter.stdout

            example_tls, example_tls_port = make_tls_listener(directory)
            example_environment = dict(environment)
            example_environment["CONVEX_URL"] = (
                f"https://localhost:{example_tls_port}")
            example = subprocess.run(
                [sys.argv[3]], timeout=5, text=True, capture_output=True,
                env=example_environment, check=False)
            example_tls.close()
            assert example.returncode != 0
            assert "current query count was 9, expected 0" in (
                example.stdout + example.stderr)
    if close_error:
        sys.stderr.write(f"fixture server failed: {close_error!r}\n")
    if completed.returncode:
        sys.stderr.write(completed.stdout + completed.stderr)
        raise SystemExit(completed.returncode)
    if close_error:
        raise close_error
    print(completed.stdout, end="")


if __name__ == "__main__":
    main()
