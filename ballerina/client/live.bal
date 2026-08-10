import ballerina/lang.runtime;
import ballerina/time;
import ballerina/uuid;

// The Live query-set state machine: one background strand ("the owner") has
// exclusive ownership of the WebSocket, the reconnect/backoff timer, and the
// query-set version. Every other strand only ever pushes a `Command` and
// polls the matching `Reply` - see `command_queue.bal` for why those types
// are shaped the way they are.

const decimal INITIAL_BACKOFF = 0.1;
const decimal MAX_BACKOFF = 15.0;
// Every owner-loop response documented above (Add, Remove, debugDisconnect,
// Close) is a fixed, cheap local state change - the socket write it may
// attempt has its own FRAME_DEADLINE. This budget only needs to cover a
// caller strand actually getting scheduled promptly, which is where the
// margin matters under real contention (many strands, JIT warm-up, GC)
// rather than under this repository's own light local test load.
const decimal OWNER_RESPONSE_TIMEOUT = 3.0;
const decimal CONNECT_DEADLINE = 8.0;
const decimal FRAME_DEADLINE = 2.0;
const string INITIAL_TS = "AAAAAAAAAAA=";

// Every wire record below is an *open* record (no closing `|verify_here|`),
// deliberately: the real server's Transition carries fields this
// demonstration has no use for - `clientClockSkew` and `serverTs` on the
// envelope, `journal` on each QueryUpdated - and a closed record rejects a
// JSON object outright the moment it carries a field the record does not
// declare. A native client speaking a real, evolving server protocol has to
// tolerate fields it does not know about; only the ones it actually reads
// are declared and required.
type StateVersion record {
    int querySet;
    int identity;
    string ts;
};

function zeroVersion() returns StateVersion => {querySet: 0, identity: 0, ts: INITIAL_TS};

type QueryUpdated record {
    "QueryUpdated" 'type;
    int queryId;
    json value = ();
    string[] logLines = [];
};

type QueryFailed record {
    "QueryFailed" 'type;
    int queryId;
    string errorMessage;
    json errorData = ();
    string[] logLines = [];
};

type QueryRemoved record {
    "QueryRemoved" 'type;
    int queryId;
};

type Modification QueryUpdated|QueryFailed|QueryRemoved;

type WireTransition record {
    "Transition" 'type;
    StateVersion startVersion;
    StateVersion endVersion;
    Modification[] modifications;
};

// Local, single-strand state for one active subscription. Never crosses a
// lock, so its `Mailbox` field is unremarkable here (see command_queue.bal
// for why the same field would need special handling inside isolated state).
type ActiveSub record {|
    string path;
    json & readonly args;
    Mailbox mailbox;
|};

function addModification(int id, string path, json args) returns json =>
    {'type: "Add", queryId: id, udfPath: path, args: [args]};

function connectMessage(int connectionCount, string lastCloseReason, string? maxObservedTimestamp) returns json {
    map<json> message = {
        'type: "Connect",
        sessionId: uuid:createType1AsString(),
        connectionCount: connectionCount,
        lastCloseReason: lastCloseReason,
        clientTs: 0
    };
    if maxObservedTimestamp is string {
        message["maxObservedTimestamp"] = maxObservedTimestamp;
    }
    return message;
}

# Dials a new TCP(+TLS) connection, performs the WebSocket handshake, sends
# `Connect`, then re-adds every currently active subscription in one
# `ModifyQuerySet` batch so a reconnect resumes exactly where it left off.
# Returns the new socket/buffer pair and the query-set version it just
# established; the caller (the owner loop) only swaps its state in once this
# entire sequence has succeeded.
function installConnection(
        string host,
        int port,
        boolean useTls,
        string caCertPath,
        string path,
        map<ActiveSub> active,
        int connectionCount,
        string lastCloseReason,
        string? maxObservedTimestamp
) returns [RawSocket, SocketBuffer, int]|TransportError {
    RawSocket sock = new;
    // ballerina/tcp's own TLS client never sends SNI (confirmed by
    // disassembling its native jar - see raw_socket.bal), which fails the
    // handshake outright against any SNI-requiring TLS endpoint, effectively
    // every real deployment. `RawSocket` uses the JDK's own SSLSocketFactory
    // for TLS instead and ballerina/tcp only for the plaintext local case.
    // FRAME_DEADLINE, not CONNECT_DEADLINE: this governs the underlying
    // socket's own per-read/per-write timeout for the connection's entire
    // lifetime, not just the connect+handshake sequence below, whose own
    // logical deadline is CONNECT_DEADLINE, tracked separately via
    // `time:monotonicNow()`. Passing CONNECT_DEADLINE here instead would
    // quadruple every subsequent idle-frame read's blocking time.
    TransportError? connectError = useTls
        ? sock.initTls(host, port, FRAME_DEADLINE)
        : sock.initPlain(host, port, FRAME_DEADLINE);
    if connectError is TransportError {
        return connectError;
    }
    SocketBuffer buffer = new (sock);
    decimal handshakeDeadline = time:monotonicNow() + CONNECT_DEADLINE;
    TransportError? handshakeError = performHandshake(buffer, host, path, handshakeDeadline);
    if handshakeError is TransportError {
        TransportError? closeAfterHandshakeError = sock.close();
        return handshakeError;
    }

    TransportError? connectSendError = writeFrame(sock, OPCODE_TEXT, connectMessage(connectionCount, lastCloseReason, maxObservedTimestamp).toJsonString().toBytes());
    if connectSendError is TransportError {
        TransportError? closeAfterConnectError = sock.close();
        return connectSendError;
    }

    json[] modifications = [];
    foreach [string, ActiveSub] [idText, sub] in active.entries() {
        int|error idNum = int:fromString(idText);
        if idNum is int {
            modifications.push(addModification(idNum, sub.path, sub.args));
        }
    }
    int newVersion = 0;
    if modifications.length() > 0 {
        json batch = {'type: "ModifyQuerySet", baseVersion: 0, newVersion: 1, modifications: modifications};
        TransportError? addError = writeFrame(sock, OPCODE_TEXT, batch.toJsonString().toBytes());
        if addError is TransportError {
            TransportError? closeAfterAddError = sock.close();
            return addError;
        }
        newVersion = 1;
    }

    return [sock, buffer, newVersion];
}

# The owner loop. Runs for the lifetime of the `Live` value on its own
# strand, started exactly once by `Live.start`. Every field below is a plain
# local variable: nothing outside this function ever reads or writes them
# directly, so none of it needs to be isolated state.
function runLiveOwner(string host, int port, boolean useTls, string caCertPath, string wsPath, CommandQueue commands) {
    map<ActiveSub> active = {};
    int nextId = 0;
    RawSocket? socket = ();
    SocketBuffer? buffer = ();
    int querySetVersion = 0;
    StateVersion remoteVersion = zeroVersion();
    string? maxObservedTimestamp = ();
    int connectionCount = 0;
    string lastCloseReason = "InitialConnect";
    decimal retryBackoff = INITIAL_BACKOFF;
    decimal reconnectDue = time:monotonicNow();

    // Tears down the active socket (if any) and schedules the next reconnect
    // attempt with exponential backoff. Query-set state resets because the
    // next connection starts a brand-new sync-protocol session.
    function (string) disconnect = function(string reason) {
        RawSocket? current = socket;
        if current is RawSocket {
            TransportError? closeErr = current.close();
            connectionCount += 1;
        }
        socket = ();
        buffer = ();
        lastCloseReason = reason;
        querySetVersion = 0;
        remoteVersion = zeroVersion();
        if active.length() > 0 {
            reconnectDue = time:monotonicNow() + retryBackoff;
            retryBackoff = retryBackoff * 2 > MAX_BACKOFF ? MAX_BACKOFF : retryBackoff * 2;
        }
    };

    function () markValidTraffic = function() {
        retryBackoff = INITIAL_BACKOFF;
    };

    function (string) protocolFailure = function(string message) {
        foreach ActiveSub sub in active {
            sub.mailbox.push({value: (), err: error ProtocolError(message, logs = []), logs: []});
        }
        disconnect("convex protocol error: " + message);
    };

    while true {
        // Drain every queued command before touching the socket, so Add is a
        // real barrier: its reply is not sent until state is installed and
        // any required write attempted.
        while true {
            Command? next = commands.tryPop();
            if next is () {
                break;
            }
            if next is AddCommand {
                int id = nextId;
                nextId += 1;
                Mailbox mailbox = new;
                active[id.toString()] = {path: next.path, args: next.args, mailbox};
                RawSocket? current = socket;
                if current is RawSocket {
                    json message = {'type: "ModifyQuerySet", baseVersion: querySetVersion, newVersion: querySetVersion + 1, modifications: [addModification(id, next.path, next.args)]};
                    TransportError? sendError = writeFrame(current, OPCODE_TEXT, message.toJsonString().toBytes());
                    if sendError is TransportError {
                        disconnect(sendError.message());
                    } else {
                        querySetVersion += 1;
                    }
                } else if reconnectDue > time:monotonicNow() {
                    reconnectDue = time:monotonicNow();
                }
                next.reply.succeed(id, mailbox);
            } else if next is SimpleCommand {
                if next.kind == CMD_REMOVE {
                    string key = next.removeId.toString();
                    ActiveSub? removed = active[key];
                    if removed is ActiveSub {
                        ActiveSub removedEntry = active.remove(key);
                        removed.mailbox.close();
                        RawSocket? current = socket;
                        if current is RawSocket {
                            json message = {'type: "ModifyQuerySet", baseVersion: querySetVersion, newVersion: querySetVersion + 1, modifications: [{'type: "Remove", queryId: next.removeId}]};
                            TransportError? sendError = writeFrame(current, OPCODE_TEXT, message.toJsonString().toBytes());
                            if sendError is TransportError {
                                disconnect(sendError.message());
                            } else {
                                querySetVersion += 1;
                            }
                        }
                    }
                    next.reply.succeed();
                } else if next.kind == CMD_DEBUG_DISCONNECT {
                    // The peer may have closed, or a read may have failed,
                    // immediately before this command reached the owner. In
                    // that case `disconnect` has already retired the old
                    // socket and scheduled the reconnect. The adapter's
                    // barrier is still satisfied, so acknowledge it instead
                    // of turning that benign race into a TransportError.
                    disconnect("adapter debug disconnect");
                    next.reply.succeed();
                } else {
                    // CMD_CLOSE
                    RawSocket? current = socket;
                    if current is RawSocket {
                        TransportError? closeOnShutdown = current.close();
                    }
                    foreach ActiveSub sub in active {
                        sub.mailbox.close();
                    }
                    active = {};
                    next.reply.succeed();
                    return;
                }
            }
        }

        // Dial a fresh connection when one is due. This runs inline on the
        // owner strand: a reconnect attempt therefore delays the next
        // command by at most CONNECT_DEADLINE, a deliberate simplification
        // documented in the README rather than a background connector
        // strand racing the owner's own state.
        if socket is () && active.length() > 0 && time:monotonicNow() >= reconnectDue {
            [RawSocket, SocketBuffer, int]|TransportError attempt = installConnection(host, port, useTls, caCertPath, wsPath, active, connectionCount, lastCloseReason, maxObservedTimestamp);
            if attempt is TransportError {
                disconnect(attempt.message());
            } else {
                [RawSocket, SocketBuffer, int] [newSocket, newBuffer, newVersion] = attempt;
                socket = newSocket;
                buffer = newBuffer;
                querySetVersion = newVersion;
                remoteVersion = zeroVersion();
                // Backoff is deliberately not reset here: a handshake and
                // client writes do not prove the server has sent anything.
            }
        }

        SocketBuffer? currentBuffer = buffer;
        RawSocket? currentSocket = socket;
        if currentBuffer is SocketBuffer && currentSocket is RawSocket {
            decimal tickDeadline = time:monotonicNow() + 0.05;
            FrameResult|TransportError result = readMessage(currentBuffer, currentSocket, tickDeadline);
            if result is FrameResult {
                if result.closed {
                    disconnect("peer sent WebSocket Close");
                } else {
                    string? text = result.text;
                    if text is string {
                        handleServerMessage(text, active, remoteVersion, markValidTraffic, protocolFailure, function(StateVersion v) {
                                    remoteVersion = v;
                                }, function(string ts) {
                                    maxObservedTimestamp = ts;
                                });
                    }
                }
            } else {
                // A tick deadline is expected to expire routinely when the
                // peer is simply idle; only treat it as a disconnect once it
                // is indistinguishable from one on this connection.
                if !result.message().includes("deadline") {
                    disconnect(result.message());
                }
            }
        }

        runtime:sleep(0.002);
    }
}

# Decodes one server text message and applies it to the active subscriptions.
# Called synchronously from the owner's own strand (never `start`ed or shared),
# so it takes every piece of owner state it needs as a plain parameter or
# callback rather than through any lock.
function handleServerMessage(
        string text,
        map<ActiveSub> active,
        StateVersion remoteVersion,
        function () markValidTraffic,
        function (string) protocolFailure,
        function (StateVersion) setRemoteVersion,
        function (string) setMaxObservedTimestamp
) {
    json|error parsed = text.fromJsonString();
    if parsed is error {
        protocolFailure("decode server message: " + parsed.message());
        return;
    }
    json typeField = parsed is map<json> ? parsed["type"] : ();
    string kind = typeField is string ? typeField : "";

    if kind == "Transition" {
        WireTransition|error transition = text.fromJsonStringWithType();
        if transition is error {
            protocolFailure("decode Transition: " + transition.message());
            return;
        }
        if transition.startVersion.querySet != remoteVersion.querySet ||
            transition.startVersion.identity != remoteVersion.identity ||
            transition.startVersion.ts != remoteVersion.ts {
            protocolFailure("Transition start version does not match local version");
            return;
        }
        if transition.endVersion.ts.trim().length() == 0 {
            protocolFailure("Transition end timestamp is empty");
            return;
        }
        // Build every publish before touching a mailbox, so a malformed
        // modification anywhere in the batch commits nothing.
        foreach Modification modification in transition.modifications {
            if modification is QueryUpdated {
                ActiveSub? sub = active[modification.queryId.toString()];
                if sub is ActiveSub {
                    sub.mailbox.push({value: modification.value, err: (), logs: modification.logLines});
                }
            } else if modification is QueryFailed {
                ActiveSub? sub = active[modification.queryId.toString()];
                if sub is ActiveSub {
                    ConvexError functionError = error FunctionError(modification.errorMessage, operation = "query", data = modification.errorData, logs = modification.logLines);
                    sub.mailbox.push({value: (), err: functionError, logs: modification.logLines});
                }
            }
            // QueryRemoved needs no delivery: the subscription's own Remove
            // command already closed its mailbox.
        }
        setRemoteVersion(transition.endVersion);
        setMaxObservedTimestamp(transition.endVersion.ts);
        markValidTraffic();
        return;
    }
    if kind == "Ping" || kind == "MutationResponse" || kind == "ActionResponse" {
        markValidTraffic();
        return;
    }
    if kind == "FatalError" || kind == "AuthError" {
        protocolFailure(kind + " from Live server");
        return;
    }
    if kind == "TransitionChunk" {
        protocolFailure("TransitionChunk assembly is not implemented by this demonstration");
        return;
    }
    protocolFailure("unknown server message " + kind);
}

# Public handle to the background Live owner. Not an `isolated class` (see
# the note at the top of convex_client.bal): every caller in this repository
# uses one `Live` from a single strand, and `CommandQueue` - which genuinely
# is `isolated` - is what actually needs to be safe across the owner strand
# and every caller strand.
public class Live {
    private final CommandQueue commands;

    // Ballerina classes have no static methods, so construction and starting
    // the owner strand happen together here rather than through a separate
    // factory method.
    function init(string host, int port, boolean useTls, string caCertPath, string wsPath) {
        CommandQueue commands = new;
        self.commands = commands;
        future<()> ownerTask = start runLiveOwner(host, port, useTls, caCertPath, wsPath, commands);
    }

    public function subscribe(string path, json args) returns Subscription|ConvexError {
        SubscribeReply reply = new;
        json & readonly frozenArgs = args.cloneReadOnly();
        AddCommand command = new (path, frozenArgs, reply);
        self.commands.push(command);
        SubscribeOutcome|ConvexError outcome = reply.awaitOutcome(OWNER_RESPONSE_TIMEOUT);
        if outcome is ConvexError {
            return outcome;
        }
        return new Subscription(outcome.id, self, outcome.mailbox);
    }

    function removeSubscription(int id) returns ConvexError? {
        UnitReply reply = new;
        SimpleCommand command = new (CMD_REMOVE, id, reply);
        self.commands.push(command);
        return reply.awaitOutcome(OWNER_RESPONSE_TIMEOUT);
    }

    public function debugDisconnect() returns ConvexError? {
        UnitReply reply = new;
        SimpleCommand command = new (CMD_DEBUG_DISCONNECT, 0, reply);
        self.commands.push(command);
        return reply.awaitOutcome(OWNER_RESPONSE_TIMEOUT);
    }

    public function close() returns ConvexError? {
        UnitReply reply = new;
        SimpleCommand command = new (CMD_CLOSE, 0, reply);
        self.commands.push(command);
        return reply.awaitOutcome(OWNER_RESPONSE_TIMEOUT);
    }
}

public class Subscription {
    private final int id;
    private final Live manager;
    private final Mailbox mailbox;
    private boolean closed = false;

    function init(int id, Live manager, Mailbox mailbox) {
        self.id = id;
        self.manager = manager;
        self.mailbox = mailbox;
    }

    public function updates() returns Mailbox {
        return self.mailbox;
    }

    public function close() returns ConvexError? {
        if self.closed {
            return ();
        }
        self.closed = true;
        return self.manager.removeSubscription(self.id);
    }
}
