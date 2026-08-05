import json
import base64
import hashlib
import socket
import threading
import time
import unittest

from convex import ProtocolError, TransportError, _LiveManager, _WebSocket


def websocket_over(sock, buffered=b""):
    websocket = _WebSocket.__new__(_WebSocket)
    websocket.sock = sock
    websocket._buffer = buffered
    return websocket


class TestWebSocketFrames(unittest.TestCase):
    def handshake_server(self, response_builder, leftover=b""):
        server = socket.create_server(("127.0.0.1", 0))
        port = server.getsockname()[1]

        def serve():
            connection, _ = server.accept()
            request = b""
            while b"\r\n\r\n" not in request:
                request += connection.recv(4096)
            key = next(
                line.split(b":", 1)[1].strip()
                for line in request.split(b"\r\n")
                if line.lower().startswith(b"sec-websocket-key:")
            )
            accept = base64.b64encode(
                hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()
            ).decode()
            connection.sendall(response_builder(accept).encode() + leftover)
            time.sleep(0.1)
            connection.close()
            server.close()

        thread = threading.Thread(target=serve)
        thread.start()
        self.addCleanup(thread.join)
        return f"ws://127.0.0.1:{port}/api/sync"

    def test_constructor_validates_upgrade_and_preserves_first_frame(self):
        message = json.dumps({"type": "Ping"}).encode()
        frame = bytes([0x81, len(message)]) + message
        url = self.handshake_server(
            lambda accept: f"HTTP/1.1 101 Switching Protocols\r\nUpGrAdE: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n",
            frame,
        )
        websocket = _WebSocket(url, "test")
        self.addCleanup(websocket.close)
        self.assertEqual(websocket.receive_json(), {"type": "Ping"})

    def test_constructor_rejects_each_required_upgrade_header(self):
        responses = [
            lambda accept: f"HTTP/1.1 200 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n",
            lambda accept: f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n",
            lambda accept: f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Accept: {accept}\r\n\r\n",
            lambda accept: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n",
        ]
        for response in responses:
            with self.subTest(response=response):
                with self.assertRaises(TransportError):
                    _WebSocket(self.handshake_server(response), "test")

    def test_ping_payload_is_echoed_in_a_masked_pong(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        text = b'{"type":"Ping"}'
        right.sendall(b"\x89\x03hey" + bytes([0x81, len(text)]) + text)
        websocket = websocket_over(left)
        self.assertEqual(websocket.receive_json(), {"type": "Ping"})
        first, second = right.recv(2)
        self.assertEqual(first, 0x8A)
        self.assertTrue(second & 0x80)
        size = second & 0x7F
        mask = right.recv(4)
        payload = right.recv(size)
        self.assertEqual(
            bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)), b"hey"
        )

    def test_rejects_fragmented_rsv_masked_and_invalid_control_frames(self):
        cases = [
            b"\x01\x02{}",
            b"\xc1\x02{}",
            b"\x81\x82maskxx",
            b"\x09\x00",
            b"\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00",
        ]
        for frame in cases:
            with self.subTest(frame=frame):
                left, right = socket.socketpair()
                self.addCleanup(left.close)
                self.addCleanup(right.close)
                right.sendall(frame)
                with self.assertRaises(ProtocolError):
                    websocket_over(left).receive_json()


class FakeWebSocket:
    def __init__(self, *_):
        self.closed = threading.Event()
        self.entered = threading.Event()
        self.sent = []

    def send_json(self, value):
        self.sent.append(value)

    def receive_json(self):
        self.entered.set()
        self.closed.wait(2)
        raise EOFError()

    def close(self):
        self.closed.set()


class TestLiveLifecycle(unittest.TestCase):
    def setUp(self):
        self.sockets = []

        def factory(*args):
            result = FakeWebSocket(*args)
            self.sockets.append(result)
            return result

        self.manager = _LiveManager("http://example.test", "test", factory)

    def tearDown(self):
        self.manager.close()

    def test_unsubscribe_does_not_wait_for_blocking_receive(self):
        subscription = self.manager.subscribe("demo:state", {"room": "one"})
        while not self.sockets:
            time.sleep(0.01)
        self.assertTrue(self.sockets[0].entered.wait(1))
        started = time.monotonic()
        subscription.close()
        self.assertLess(time.monotonic() - started, 0.25)

    def test_debug_disconnect_unblocks_receive_and_reconnects(self):
        subscription = self.manager.subscribe("demo:state", {"room": "one"})
        while not self.sockets:
            time.sleep(0.01)
        self.assertTrue(self.sockets[0].entered.wait(1))
        self.manager.disconnect_for_adapter()
        deadline = time.monotonic() + 1
        while len(self.sockets) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertGreaterEqual(len(self.sockets), 2)
        connect_frames = [socket.sent[0] for socket in self.sockets[:2]]
        self.assertEqual([frame["connectionCount"] for frame in connect_frames], [0, 1])
        self.assertEqual(connect_frames[1]["lastCloseReason"], "DebugDisconnect")
        self.manager._transition(
            {
                "type": "Transition",
                "startVersion": dict(self.manager.INITIAL_VERSION),
                "endVersion": {"querySet": 1, "identity": 0, "ts": "AQAAAAAAAAA="},
                "modifications": [
                    {
                        "type": "QueryUpdated",
                        "queryId": subscription.query_id,
                        "value": {"count": 0},
                        "logLines": [],
                    }
                ],
            }
        )
        update = subscription.next_update(0.2)
        self.assertIsNone(update.error)
        self.assertEqual(update.value, {"count": 0})
