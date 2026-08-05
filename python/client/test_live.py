import json
import socket
import threading
import time
import unittest

from convex import ProtocolError, _LiveManager, _WebSocket


def websocket_over(sock, buffered=b''):
    websocket = _WebSocket.__new__(_WebSocket)
    websocket.sock = sock
    websocket._buffer = buffered
    return websocket


class TestWebSocketFrames(unittest.TestCase):
    def test_upgrade_leftovers_are_consumed_before_socket_bytes(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close); self.addCleanup(right.close)
        message = json.dumps({'type': 'Ping'}).encode()
        websocket = websocket_over(left, bytes([0x81, len(message)]) + message)
        self.assertEqual(websocket.receive_json(), {'type': 'Ping'})

    def test_ping_payload_is_echoed_in_a_masked_pong(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close); self.addCleanup(right.close)
        text = b'{"type":"Ping"}'
        right.sendall(b'\x89\x03hey' + bytes([0x81, len(text)]) + text)
        websocket = websocket_over(left)
        self.assertEqual(websocket.receive_json(), {'type': 'Ping'})
        first, second = right.recv(2)
        self.assertEqual(first, 0x8A); self.assertTrue(second & 0x80)
        size = second & 0x7F; mask = right.recv(4); payload = right.recv(size)
        self.assertEqual(bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)), b'hey')

    def test_rejects_fragmented_rsv_masked_and_invalid_control_frames(self):
        cases = [b'\x01\x02{}', b'\xc1\x02{}', b'\x81\x82maskxx', b'\x09\x00', b'\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00']
        for frame in cases:
            with self.subTest(frame=frame):
                left, right = socket.socketpair(); self.addCleanup(left.close); self.addCleanup(right.close)
                right.sendall(frame)
                with self.assertRaises(ProtocolError): websocket_over(left).receive_json()


class FakeWebSocket:
    def __init__(self, *_): self.closed = threading.Event(); self.entered = threading.Event(); self.sent = []
    def send_json(self, value): self.sent.append(value)
    def receive_json(self): self.entered.set(); self.closed.wait(2); raise EOFError()
    def close(self): self.closed.set()


class TestLiveLifecycle(unittest.TestCase):
    def setUp(self):
        self.sockets = []
        def factory(*args):
            result = FakeWebSocket(*args); self.sockets.append(result); return result
        self.manager = _LiveManager('http://example.test', 'test', factory)
    def tearDown(self): self.manager.close()

    def test_unsubscribe_does_not_wait_for_blocking_receive(self):
        subscription = self.manager.subscribe('demo:state', {'room':'one'})
        while not self.sockets: time.sleep(.01)
        self.assertTrue(self.sockets[0].entered.wait(1))
        started = time.monotonic(); subscription.close()
        self.assertLess(time.monotonic() - started, .25)

    def test_debug_disconnect_unblocks_receive_and_reconnects(self):
        self.manager.subscribe('demo:state', {'room':'one'})
        while not self.sockets: time.sleep(.01)
        self.assertTrue(self.sockets[0].entered.wait(1))
        self.manager.disconnect_for_adapter()
        deadline=time.monotonic()+1
        while len(self.sockets) < 2 and time.monotonic() < deadline: time.sleep(.01)
        self.assertGreaterEqual(len(self.sockets), 2)
