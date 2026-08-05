"""A deliberately small, native Python Convex demonstration client."""
import base64
import hashlib
import json
import os
import queue
import secrets
import socket
import ssl
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass


class ConvexError(Exception): pass
class ClosedError(ConvexError): pass
class ProtocolError(ConvexError): pass
class TransportError(ConvexError): pass


class FunctionError(ConvexError):
    def __init__(self, message, *, data=None, logs=None):
        super().__init__(message); self.data = data; self.logs = logs or []


@dataclass
class Result:
    value: object
    logs: list


@dataclass
class Update:
    value: object = None
    error: Exception | None = None
    logs: list | None = None


class _WebSocket:
    # RFC 6455 framing is kept here instead of hiding Convex behaviour behind a
    # third-party SDK. It supports the text frames used by the pinned profile.
    def __init__(self, url, client_version):
        parsed = urllib.parse.urlparse(url)
        raw = socket.create_connection((parsed.hostname, parsed.port or (443 if parsed.scheme == "wss" else 80)), 10)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=parsed.hostname) if parsed.scheme == "wss" else raw
        key = base64.b64encode(os.urandom(16)).decode()
        path = (parsed.path or "/") + (("?" + parsed.query) if parsed.query else "")
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {parsed.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nConvex-Client: {client_version}\r\n\r\n").encode())
        response = self._read_until(b"\r\n\r\n")
        if not response.startswith(b"HTTP/1.1 101") or base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()) not in response:
            self.close(); raise TransportError("WebSocket upgrade was rejected")

    def _read_until(self, marker):
        data = b""
        while marker not in data:
            chunk = self.sock.recv(4096)
            if not chunk: raise TransportError("WebSocket closed during upgrade")
            data += chunk
        return data

    def _exact(self, length):
        data = b""
        while len(data) < length:
            chunk = self.sock.recv(length - len(data))
            if not chunk: raise EOFError
            data += chunk
        return data

    def send_json(self, value):
        payload = json.dumps(value, separators=(",", ":")).encode(); mask = os.urandom(4)
        size = len(payload)
        head = bytes([0x81, 0x80 | (size if size < 126 else 126 if size < 65536 else 127)])
        if size >= 65536: head += struct.pack("!Q", size)
        elif size >= 126: head += struct.pack("!H", size)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def receive_json(self):
        first, second = self._exact(2); opcode = first & 15; size = second & 127
        if size == 126: size = struct.unpack("!H", self._exact(2))[0]
        elif size == 127: size = struct.unpack("!Q", self._exact(8))[0]
        mask = self._exact(4) if second & 128 else None; data = self._exact(size)
        if mask: data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        if opcode == 8: raise EOFError
        if opcode == 9: self.sock.sendall(b"\x8a\x00"); return self.receive_json()
        if opcode != 1: raise ProtocolError(f"unsupported WebSocket opcode {opcode}")
        return json.loads(data)

    def close(self):
        try: self.sock.close()
        except Exception: pass


class Subscription:
    MAX_BUFFERED_UPDATES = 16
    def __init__(self, manager, query_id): self.manager, self.query_id, self.updates, self.closed = manager, query_id, queue.Queue(self.MAX_BUFFERED_UPDATES), False
    def next_update(self, timeout=None):
        try: update = self.updates.get(timeout=timeout)
        except queue.Empty: raise TransportError("timed out waiting for Live update")
        if isinstance(update, ClosedError): raise update
        return update
    def deliver(self, update):
        if not self.closed:
            try: self.updates.put_nowait(update)
            except queue.Full:
                try: self.updates.get_nowait()
                except queue.Empty: pass
                self.updates.put_nowait(update)
    def close(self):
        if not self.closed: self.closed = True; self.manager.unsubscribe(self.query_id)


class _LiveManager:
    INITIAL_VERSION = {"querySet": 0, "identity": 0, "ts": "AAAAAAAAAAA="}
    def __init__(self, url, version):
        p = urllib.parse.urlparse(url); self.url = urllib.parse.urlunparse(("wss" if p.scheme == "https" else "ws", p.netloc, p.path.rstrip("/") + "/api/sync", "", "", "")); self.version = version
        self.subs, self.socket, self.lock, self.closed, self.connection_count = {}, None, threading.RLock(), False, 0
        self.thread = threading.Thread(target=self._run, daemon=True); self.thread.start()
    def subscribe(self, path, args):
        with self.lock:
            ident = max(self.subs, default=-1) + 1; sub = Subscription(self, ident); self.subs[ident] = (path, args, sub)
            if self.socket: self._modify([self._add(ident, path, args)])
            return sub
    def unsubscribe(self, ident):
        with self.lock:
            if self.subs.pop(ident, None) and self.socket: self._modify([{ "type": "Remove", "queryId": ident }])
    def _add(self, ident, path, args): return {"type":"Add", "queryId":ident, "udfPath":path, "args":[args]}
    def _connect(self):
        self.socket = _WebSocket(self.url, self.version); self.query_version = 0; self.remote_version = dict(self.INITIAL_VERSION)
        self.socket.send_json({"type":"Connect", "sessionId":secrets.token_hex(16), "connectionCount":self.connection_count, "lastCloseReason":"InitialConnect", "clientTs":0})
        self._modify([self._add(i, p, a) for i, (p,a,_) in self.subs.items()])
    def _modify(self, mods):
        if not mods: return
        self.socket.send_json({"type":"ModifyQuerySet", "baseVersion":self.query_version, "newVersion":self.query_version + 1, "modifications":mods}); self.query_version += 1
    def _run(self):
        while not self.closed:
            try:
                with self.lock:
                    if not self.subs: time.sleep(.05); continue
                    if not self.socket: self._connect()
                    message = self.socket.receive_json()
                if message.get("type") == "Transition": self._transition(message)
                elif message.get("type") in ("Ping", "MutationResponse", "ActionResponse"): pass
                elif message.get("type") == "TransitionChunk": raise ProtocolError("TransitionChunk assembly is deferred")
                else: raise ProtocolError(f"unexpected Live message {message.get('type')!r}")
            except Exception as error:
                with self.lock:
                    if self.socket: self.socket.close(); self.socket = None; self.connection_count += 1
                    for _,_,sub in self.subs.values(): sub.deliver(Update(error=error, logs=[]))
                time.sleep(.1)
    def _transition(self, message):
        if message.get("startVersion") != self.remote_version: raise ProtocolError("Transition start version does not match local version")
        changed=[]
        for mod in message.get("modifications", []):
            ident=mod["queryId"]
            if mod["type"] == "QueryUpdated": changed.append((ident, Update(mod.get("value"), logs=mod.get("logLines", []))))
            elif mod["type"] == "QueryFailed": changed.append((ident, Update(error=FunctionError(mod.get("errorMessage", "query failed"), data=mod.get("errorData"), logs=mod.get("logLines", [])), logs=mod.get("logLines", []))))
            elif mod["type"] != "QueryRemoved": raise ProtocolError(f"unknown Transition modification {mod['type']!r}")
        self.remote_version=message["endVersion"]
        with self.lock:
            for ident,update in changed:
                if ident in self.subs: self.subs[ident][2].deliver(update)
    def disconnect_for_adapter(self):
        with self.lock:
            if not self.socket: raise TransportError("Live WebSocket is not connected")
            self.socket.close(); self.socket=None
    def close(self):
        self.closed=True
        with self.lock:
            if self.socket: self.socket.close()
            for _,_,sub in self.subs.values(): sub.deliver(ClosedError("Live subscription is closed"))


class Client:
    VERSION = "python-0.1.0"
    def __init__(self, deployment_url, bearer_token=None):
        p=urllib.parse.urlparse(deployment_url)
        if p.scheme not in ("http", "https") or not p.hostname or p.username: raise ValueError("Convex deployment URL must be an http(s) URL with a host")
        self.url=deployment_url.rstrip("/"); self.token=bearer_token or ""; self.closed=False; self.live=None
    def set_auth(self, token): self._check(); self.token=token or ""
    def _check(self):
        if self.closed: raise ClosedError("Convex client is closed")
    def _call(self, operation, path, args):
        self._check()
        if not isinstance(args, dict) or not path: raise ValueError("Convex path and named object arguments are required")
        request=urllib.request.Request(self.url + "/api/" + operation, data=json.dumps({"path":path,"args":args,"format":"json"}).encode(), headers={"Content-Type":"application/json", "Accept":"application/json", "Convex-Client":self.VERSION, **({"Authorization":"Bearer " + self.token} if self.token else {})}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=30) as response: decoded=json.load(response)
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as error: raise TransportError(str(error)) from error
        if decoded.get("status") == "success" and "value" in decoded: return Result(decoded["value"], decoded.get("logLines", []))
        if decoded.get("status") == "error": raise FunctionError(decoded.get("errorMessage", "Convex function failed"), data=decoded.get("errorData"), logs=decoded.get("logLines", []))
        raise ProtocolError("unknown Convex HTTP response")
    def query(self,path,args=None): return self._call("query",path,args or {})
    def mutation(self,path,args=None): return self._call("mutation",path,args or {})
    def action(self,path,args=None): return self._call("action",path,args or {})
    def subscribe(self,path,args=None):
        self._check(); self.live=self.live or _LiveManager(self.url,self.VERSION); return self.live.subscribe(path,args or {})
    def debug_disconnect_for_adapter(self): self._check(); self.live.disconnect_for_adapter() if self.live else (_ for _ in ()).throw(TransportError("Live WebSocket is not connected"))
    def close(self):
        if not self.closed: self.closed=True; self.live and self.live.close()
