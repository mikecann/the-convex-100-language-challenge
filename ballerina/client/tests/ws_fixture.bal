import ballerina/crypto;
import ballerina/lang.runtime;
import ballerina/tcp;
import ballerina/time;

// A minimal, real TCP+WebSocket peer used only by this module's own tests
// (see live_test.bal). It performs a real RFC 6455 server handshake and lets
// a test script send arbitrary raw frames - including ones this client's own
// `writeFrame` would never produce, such as an unfragmented server frame
// deliberately split mid-character with a Ping interleaved - so the tests
// below exercise the exact defect class this client exists to avoid rather
// than only the frames its own writer happens to generate.

const string TEST_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

isolated class WsFixture {
    private tcp:Caller? caller = ();
    private byte[] inbound = [];

    isolated function onConnected(tcp:Caller c) {
        lock {
            self.caller = c;
        }
    }

    isolated function pushInbound(byte[] & readonly data) {
        lock {
            self.inbound.push(...data);
        }
    }

    isolated function takeInbound() returns byte[] {
        lock {
            byte[] & readonly copy = self.inbound.cloneReadOnly();
            self.inbound = [];
            return copy;
        }
    }

    isolated function waitConnected(decimal timeoutSeconds) returns boolean {
        decimal deadline = time:monotonicNow() + timeoutSeconds;
        while time:monotonicNow() < deadline {
            boolean got;
            lock {
                got = self.caller is tcp:Caller;
            }
            if got {
                return true;
            }
            runtime:sleep(0.005);
        }
        return false;
    }

    isolated function sendRaw(byte[] data) returns error? {
        tcp:Caller? c;
        lock {
            c = self.caller;
        }
        if c is tcp:Caller {
            return c->writeBytes(data);
        }
        return error("fixture: no connected caller");
    }
}

service class FixtureConnection {
    *tcp:ConnectionService;
    private final WsFixture fixture;
    private string handshakeBuffer = "";
    private boolean handshakeComplete = false;

    function init(WsFixture fixture) {
        self.fixture = fixture;
    }

    remote function onBytes(readonly & byte[] data) returns byte[]? {
        if self.handshakeComplete {
            self.fixture.pushInbound(data);
            return ();
        }
        string|error chunk = string:fromBytes(data);
        if chunk is error {
            return ();
        }
        self.handshakeBuffer = self.handshakeBuffer + chunk;
        if !self.handshakeBuffer.includes("\r\n\r\n") {
            return ();
        }
        string? key = ();
        foreach string line in re `\r\n`.split(self.handshakeBuffer) {
            int? colon = line.indexOf(":");
            if colon is int && line.substring(0, colon).trim().toLowerAscii() == "sec-websocket-key" {
                key = line.substring(colon + 1).trim();
            }
        }
        if key is string {
            byte[] accept = crypto:hashSha1((key + TEST_WS_GUID).toBytes(), ());
            string response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
                accept.toBase64() + "\r\n\r\n";
            error? sendResult = self.fixture.sendRaw(response.toBytes());
            if sendResult is error {
                return ();
            }
        }
        self.handshakeComplete = true;
        return ();
    }

    remote function onError(tcp:Error err) {
    }

    remote function onClose() {
    }
}

service class FixtureAcceptor {
    *tcp:Service;
    private final WsFixture fixture;

    function init(WsFixture fixture) {
        self.fixture = fixture;
    }

    remote function onConnect(tcp:Caller caller) returns tcp:ConnectionService {
        self.fixture.onConnected(caller);
        return new FixtureConnection(self.fixture);
    }
}

function startWsFixture(int port) returns WsFixture|error {
    WsFixture fixture = new;
    tcp:Listener fixtureListener = check new (port, localHost = "127.0.0.1");
    check fixtureListener.attach(new FixtureAcceptor(fixture), "fixture");
    check fixtureListener.'start();
    return fixture;
}

# An unmasked, arbitrary-FIN raw server WebSocket frame - the same shape
# `ws_build_raw_frame` provides for the Icon client's fixture, which this one
# deliberately mirrors.
function buildServerFrame(boolean fin, int opcode, byte[] payload) returns byte[] {
    byte[] frame = [<byte>((fin ? 0x80 : 0) | opcode)];
    int length = payload.length();
    if length <= 125 {
        frame.push(<byte>length);
    } else {
        frame.push(<byte>126);
        frame.push(<byte>((length >> 8) & 0xFF));
        frame.push(<byte>(length & 0xFF));
    }
    frame.push(...payload);
    return frame;
}

function buildServerTextFrame(string payload) returns byte[] => buildServerFrame(true, 1, payload.toBytes());
