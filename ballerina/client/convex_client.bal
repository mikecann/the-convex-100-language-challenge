import ballerina/http;

// The public, educational surface of this demonstration: a `Client` that
// talks Convex's documented HTTP envelope for `query`/`mutation`/`action`,
// and lazily starts one Live owner strand the first time `subscribe` is
// called. See ws_frame.bal and live.bal for why Live is hand-rolled instead
// of built on `ballerina/websocket`.
//
// `Client`, `Live`, and `Subscription` are plain classes, not `isolated
// class`: every caller in this repository (the adapter's single
// command-handling strand, the canonical example, and each unit test) only
// ever touches one of these from one strand at a time. What genuinely
// crosses strands - a `Mailbox`'s updates, a `Command`'s reply - already
// travels through `isolated class` types built for exactly that (see
// command_queue.bal and mailbox.bal); routing everything through the same
// discipline here would buy nothing and cost the isolation checker's full
// transitive reach into `ws_frame.bal` and `live.bal`.

# The CA bundle every runtime image in this repository installs from its
# base distribution. Passed to `ballerina/tcp`'s `secureSocket.cert` so the
# hand-rolled WebSocket transport trusts the same chain `ballerina/http`
# already does for HTTP queries.
const string SYSTEM_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";

type DeploymentUrl readonly & record {|
    string scheme;
    string host;
    int port;
    string pathPrefix;
|};

function parseDeploymentUrl(string url) returns DeploymentUrl|ProtocolError {
    string trimmed = url;
    while trimmed.endsWith("/") {
        trimmed = trimmed.substring(0, trimmed.length() - 1);
    }
    string scheme;
    string rest;
    if trimmed.startsWith("https://") {
        scheme = "https";
        rest = trimmed.substring(8);
    } else if trimmed.startsWith("http://") {
        scheme = "http";
        rest = trimmed.substring(7);
    } else {
        return error ProtocolError("deployment URL must be absolute http(s) without credentials", logs = []);
    }
    if rest.includes("@") {
        return error ProtocolError("deployment URL must be absolute http(s) without credentials", logs = []);
    }
    string authority = rest;
    string pathPrefix = "";
    int? slash = rest.indexOf("/");
    if slash is int {
        authority = rest.substring(0, slash);
        pathPrefix = rest.substring(slash);
    }
    if authority.length() == 0 {
        return error ProtocolError("deployment URL is missing a host", logs = []);
    }
    string host = authority;
    int port = scheme == "https" ? 443 : 80;
    int? colon = authority.lastIndexOf(":");
    if colon is int {
        string portText = authority.substring(colon + 1);
        int|error parsedPort = int:fromString(portText);
        if parsedPort is int {
            host = authority.substring(0, colon);
            port = parsedPort;
        }
    }
    return {scheme, host, port, pathPrefix};
}

public class Client {
    private final string baseUrl;
    private final http:Client httpClient;
    private final DeploymentUrl deployment;
    private string authToken = "";
    private boolean closed = false;
    private Live? live = ();

    public function init(string url) returns ConvexError? {
        DeploymentUrl|ProtocolError parsed = parseDeploymentUrl(url);
        if parsed is ProtocolError {
            return parsed;
        }
        self.deployment = parsed;
        string trimmed = url;
        while trimmed.endsWith("/") {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        self.baseUrl = trimmed;
        // Convex's HTTP API is plain HTTP/1.1. Pinning it explicitly (rather
        // than accepting the client default, which negotiates HTTP/2 and
        // loads ballerina/http's Netty HTTP/2 connection manager on the
        // first request even when the peer never speaks it) keeps this
        // client's Metaspace footprint inside the shared 128 MiB runtime
        // budget under a real TLS handshake - the same class of JVM-under-
        // 128-MiB risk this repository already diagnosed and fixed for
        // Groovy, just triggered by different Netty machinery.
        http:ClientConfiguration config = {timeout: 30, httpVersion: http:HTTP_1_1};
        if parsed.scheme == "https" {
            config.secureSocket = {cert: SYSTEM_CA_BUNDLE};
        }
        http:Client|http:ClientError created = new (self.baseUrl, config);
        if created is http:ClientError {
            return error TransportError("create HTTP client: " + created.message(), logs = []);
        }
        self.httpClient = created;
    }

    public function setAuth(string token) returns ConvexError? {
        ConvexError? openError = self.ensureOpen();
        if openError is ConvexError {
            return openError;
        }
        self.authToken = token;
        return ();
    }

    public function query(string path, json args) returns CallResult|ConvexError {
        return self.call("query", path, args);
    }

    public function mutation(string path, json args) returns CallResult|ConvexError {
        return self.call("mutation", path, args);
    }

    public function action(string path, json args) returns CallResult|ConvexError {
        return self.call("action", path, args);
    }

    function call(string operation, string path, json args) returns CallResult|ConvexError {
        ConvexError? openError = self.ensureOpen();
        if openError is ConvexError {
            return openError;
        }
        return callHttp(self.httpClient, operation, path, args, self.authToken);
    }

    public function subscribe(string path, json args) returns Subscription|ConvexError {
        ConvexError? openError = self.ensureOpen();
        if openError is ConvexError {
            return openError;
        }
        if path.length() == 0 || !(args is map<json>) {
            return error ProtocolError("Live query requires a path and object arguments", logs = []);
        }
        Live? existing = self.live;
        Live liveOwner;
        if existing is Live {
            liveOwner = existing;
        } else {
            boolean useTls = self.deployment.scheme == "https";
            Live created = new (self.deployment.host, self.deployment.port, useTls, SYSTEM_CA_BUNDLE, self.deployment.pathPrefix + "/api/sync");
            self.live = created;
            liveOwner = created;
        }
        return liveOwner.subscribe(path, args);
    }

    # Test-only hook the adapter exposes as `debugDisconnect`: forces the
    # active Live connection closed so the ordinary reconnect path runs.
    public function debugDisconnectForAdapter() returns ConvexError? {
        ConvexError? openError = self.ensureOpen();
        if openError is ConvexError {
            return openError;
        }
        Live? current = self.live;
        if current is () {
            return error ProtocolError("Live WebSocket has not been started", logs = []);
        }
        return current.debugDisconnect();
    }

    public function close() returns ConvexError? {
        if self.closed {
            return ();
        }
        self.closed = true;
        Live? current = self.live;
        if current is Live {
            return current.close();
        }
        return ();
    }

    function ensureOpen() returns ConvexError? {
        if self.closed {
            return error ClosedError("convex client is closed", logs = []);
        }
        return ();
    }
}
