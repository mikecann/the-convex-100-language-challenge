import json, threading, unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from convex import Client, FunctionError, ClosedError


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.server.seen = (
            self.path,
            self.headers,
            json.loads(self.rfile.read(length)),
        )
        body = json.dumps(self.server.reply).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class TestClient(unittest.TestCase):
    def setUp(self):
        self.http = HTTPServer(("127.0.0.1", 0), Handler)
        self.http.reply = {
            "status": "success",
            "value": {"ok": True},
            "logLines": ["log"],
        }
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()
        self.client = Client(f"http://127.0.0.1:{self.http.server_port}", "token")

    def tearDown(self):
        self.client.close()
        self.http.shutdown()
        self.thread.join()
        self.http.server_close()

    def test_query_documented_json(self):
        result = self.client.query("demo:state", {"room": "one"})
        self.assertEqual(result.value, {"ok": True})
        self.assertEqual(self.http.seen[0], "/api/query")
        self.assertEqual(self.http.seen[2]["format"], "json")
        self.assertEqual(self.http.seen[1]["Authorization"], "Bearer token")

    def test_structured_error(self):
        self.http.reply = {
            "status": "error",
            "errorMessage": "expected",
            "errorData": {"code": "X"},
            "logLines": ["before"],
        }
        with self.assertRaises(FunctionError) as caught:
            self.client.action("demo:fail", {})
        self.assertEqual(caught.exception.data, {"code": "X"})

    def test_closed(self):
        self.client.close()
        self.assertRaises(ClosedError, self.client.query, "demo:state", {})
