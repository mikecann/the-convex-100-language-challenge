import ballerina/jballerina.java;
import ballerina/lang.array;
import ballerina/tcp;

// A transport abstraction over two backends: plain `ballerina/tcp` for
// ws:// (the local self-hosted deployment), and a hand-wired
// javax.net.ssl.SSLSocket for wss:// (any real, TLS-terminated deployment).
//
// This split exists because of a confirmed defect in ballerina/tcp 1.13.8's
// own TLS client, found by disassembling its bundled native jar
// (`javap -c io/ballerina/stdlib/tcp/TcpClient.class`): its handshake calls
// Netty's single-argument `SslContext.newHandler(ByteBufAllocator)`, never
// the (allocator, host, port) overload that also configures SNI. Convex's
// hosted deployment is fronted by Cloudflare, which - like effectively every
// modern TLS-terminating CDN - requires SNI to select a certificate; without
// it the handshake fails outright with a fatal `handshake_failure` alert.
// `ballerina/http`'s TLS client (verified working against the same host,
// same trust store) is unaffected, because its Netty wiring does pass the
// remote host through to `newHandler`.
//
// The workaround uses the JDK's own `SSLSocketFactory.getDefault()`, whose
// `createSocket(String host, int port)` constructor sets SNI from the
// hostname argument by design - the same behaviour `ballerina/http` already
// relies on, just reached directly instead of through `ballerina/tcp`.
// Everything above this file (framing, the sync protocol, the owner loop)
// is unaware of which backend is in play.

isolated function sslSocketFactoryGetDefault() returns handle = @java:Method {
    name: "getDefault",
    'class: "javax.net.ssl.SSLSocketFactory"
} external;

isolated function sslSocketFactoryCreateSocket(handle factory, handle host, int port) returns handle|error = @java:Method {
    name: "createSocket",
    'class: "javax.net.ssl.SSLSocketFactory",
    paramTypes: ["java.lang.String", "int"]
} external;

isolated function socketGetOutputStream(handle sock) returns handle|error = @java:Method {
    name: "getOutputStream",
    'class: "java.net.Socket"
} external;

isolated function socketGetInputStream(handle sock) returns handle|error = @java:Method {
    name: "getInputStream",
    'class: "java.net.Socket"
} external;

isolated function socketSetSoTimeout(handle sock, int millis) returns error? = @java:Method {
    name: "setSoTimeout",
    'class: "java.net.Socket",
    paramTypes: ["int"]
} external;

isolated function socketClose(handle sock) returns error? = @java:Method {
    name: "close",
    'class: "java.net.Socket"
} external;

isolated function inputStreamReadOneByte(handle javaStream) returns int|error = @java:Method {
    name: "read",
    'class: "java.io.InputStream"
} external;

isolated function inputStreamAvailable(handle javaStream) returns int|error = @java:Method {
    name: "available",
    'class: "java.io.InputStream"
} external;

// `readNBytes(int)` blocks until it has read exactly that many bytes or
// hits EOF - never returning early with fewer. Only ever called here with a
// length already confirmed available (via `inputStreamAvailable`), so it
// cannot turn into a false, unbounded wait for bytes that are not coming.
isolated function inputStreamReadNBytesHandle(handle javaStream, int len) returns handle|error = @java:Method {
    name: "readNBytes",
    'class: "java.io.InputStream",
    paramTypes: ["int"]
} external;

isolated function outputStreamWriteHandle(handle javaStream, handle data) returns error? = @java:Method {
    name: "write",
    'class: "java.io.OutputStream",
    paramTypes: ["[B"]
} external;

isolated function outputStreamFlush(handle javaStream) returns error? = @java:Method {
    name: "flush",
    'class: "java.io.OutputStream"
} external;

isolated function base64GetEncoder() returns handle = @java:Method {
    name: "getEncoder",
    'class: "java.util.Base64"
} external;

isolated function base64EncoderEncodeToString(handle encoder, handle byteArrayHandle) returns handle = @java:Method {
    name: "encodeToString",
    'class: "java.util.Base64$Encoder"
} external;

isolated function base64GetDecoder() returns handle = @java:Method {
    name: "getDecoder",
    'class: "java.util.Base64"
} external;

isolated function base64DecoderDecode(handle decoder, handle strHandle) returns handle = @java:Method {
    name: "decode",
    'class: "java.util.Base64$Decoder",
    paramTypes: ["java.lang.String"]
} external;

// `handle` is Ballerina's opaque foreign-reference type; a Java `byte[]`
// crosses as one of these rather than as a Ballerina `byte[]` because the
// interop compiler's array-parameter matching rejects both "byte[]" and
// "[B" as a `paramTypes` entry whenever the Ballerina-side parameter or
// return type is itself declared `byte[]` (confirmed by testing every
// combination directly against this Ballerina/JDK pair). Routing the actual
// bytes through Base64 - entirely standard-library calls on both sides -
// sidesteps that compiler limitation instead of depending on it being fixed.
function javaBytesToBallerina(handle javaByteArray) returns byte[]|error {
    handle encoder = base64GetEncoder();
    handle strHandle = base64EncoderEncodeToString(encoder, javaByteArray);
    string b64 = java:toString(strHandle) ?: "";
    return array:fromBase64(b64);
}

function ballerinaBytesToJava(byte[] data) returns handle {
    string b64 = data.toBase64();
    handle strHandle = java:fromString(b64);
    handle decoder = base64GetDecoder();
    return base64DecoderDecode(decoder, strHandle);
}

# A single connected byte stream, backed by either `ballerina/tcp` (plain) or
# a directly-constructed `javax.net.ssl.SSLSocket` (TLS). Not an isolated
# class: exactly like `tcp:Client` itself, exactly one strand (the owner
# loop) ever touches a given instance.
class RawSocket {
    private tcp:Client? plainSock = ();
    private handle? javaSocket = ();
    private handle? javaIn = ();
    private handle? javaOut = ();

    function initPlain(string host, int port, decimal timeoutSeconds) returns TransportError? {
        tcp:Client|tcp:Error result = new (host, port, timeout = timeoutSeconds, writeTimeout = timeoutSeconds);
        if result is tcp:Error {
            return error TransportError("connect failed: " + result.message(), logs = []);
        }
        self.plainSock = result;
        return ();
    }

    function initTls(string host, int port, decimal timeoutSeconds) returns TransportError? {
        handle factory = sslSocketFactoryGetDefault();
        handle hostHandle = java:fromString(host);
        handle|error sockResult = sslSocketFactoryCreateSocket(factory, hostHandle, port);
        if sockResult is error {
            return error TransportError("TLS connect failed: " + sockResult.message(), logs = []);
        }
        handle sock = sockResult;
        error? timeoutSet = socketSetSoTimeout(sock, <int>(timeoutSeconds * 1000));
        if timeoutSet is error {
            return error TransportError("TLS set timeout failed: " + timeoutSet.message(), logs = []);
        }
        // Obtaining the output stream is what actually forces the TLS
        // handshake to run and complete (or fail) on this backend.
        handle|error outResult = socketGetOutputStream(sock);
        if outResult is error {
            return error TransportError("TLS handshake failed: " + outResult.message(), logs = []);
        }
        handle|error inResult = socketGetInputStream(sock);
        if inResult is error {
            return error TransportError("TLS get input stream failed: " + inResult.message(), logs = []);
        }
        self.javaSocket = sock;
        self.javaOut = outResult;
        self.javaIn = inResult;
        return ();
    }

    function writeAll(byte[] data) returns TransportError? {
        tcp:Client? plain = self.plainSock;
        if plain is tcp:Client {
            tcp:Error? sendError = plain->writeBytes(data);
            if sendError is tcp:Error {
                return error TransportError("write failed: " + sendError.message(), logs = []);
            }
            return ();
        }
        handle? out = self.javaOut;
        if out is handle {
            handle dataHandle = ballerinaBytesToJava(data);
            error? writeResult = outputStreamWriteHandle(out, dataHandle);
            if writeResult is error {
                return error TransportError("TLS write failed: " + writeResult.message(), logs = []);
            }
            error? flushResult = outputStreamFlush(out);
            if flushResult is error {
                return error TransportError("TLS flush failed: " + flushResult.message(), logs = []);
            }
            return ();
        }
        return error TransportError("socket is not connected", logs = []);
    }

    // Returns whatever is available "now": for the plain backend, exactly
    // `tcp:Client->readBytes()`'s own chunking; for TLS, one blocking byte
    // (bounding the wait the same way a plain socket recv() would) followed
    // by an immediate bulk grab of anything else already sitting in the
    // socket's receive buffer, so a multi-frame burst is not paid for one
    // interop call per byte.
    function readSome() returns byte[]|TransportError {
        tcp:Client? plain = self.plainSock;
        if plain is tcp:Client {
            readonly & byte[]|tcp:Error chunk = plain->readBytes();
            if chunk is tcp:Error {
                return error TransportError("read failed: " + chunk.message(), logs = []);
            }
            return chunk;
        }
        handle? inStream = self.javaIn;
        if inStream is handle {
            int|error first = inputStreamReadOneByte(inStream);
            if first is error {
                return error TransportError("TLS read failed: " + first.message(), logs = []);
            }
            if first == -1 {
                return error TransportError("TLS peer closed the connection", logs = []);
            }
            byte[] result = [<byte>first];
            int|error availableCount = inputStreamAvailable(inStream);
            if availableCount is int && availableCount > 0 {
                int capped = availableCount > 65536 ? 65536 : availableCount;
                handle|error restHandle = inputStreamReadNBytesHandle(inStream, capped);
                if restHandle is handle {
                    byte[]|error rest = javaBytesToBallerina(restHandle);
                    if rest is byte[] {
                        result.push(...rest);
                    }
                }
            }
            return result;
        }
        return error TransportError("socket is not connected", logs = []);
    }

    function close() returns TransportError? {
        tcp:Client? plain = self.plainSock;
        if plain is tcp:Client {
            tcp:Error? closeResult = plain->close();
            if closeResult is tcp:Error {
                return error TransportError("close failed: " + closeResult.message(), logs = []);
            }
            return ();
        }
        handle? sock = self.javaSocket;
        if sock is handle {
            error? closeResult = socketClose(sock);
            if closeResult is error {
                return error TransportError("TLS close failed: " + closeResult.message(), logs = []);
            }
        }
        return ();
    }
}
