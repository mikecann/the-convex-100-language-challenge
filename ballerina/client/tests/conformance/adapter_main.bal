import ballerina/io;
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/tcp;

// Test-only NDJSON adapter protocol v1. Not part of the public client: it
// exists so the shared black-box conformance harness can drive this Convex
// client the same way it drives every other language in this repository.
// Every operation here calls the real `convexdemo/ballerina_client` code in
// ../../*.bal - nothing about the protocol itself is reimplemented here.

const string BALLERINA_RUNTIME = "ballerina-2201.13.5";

# Every field a command line might carry. Optional fields are absent rather
# than `null` when the operation does not use them, matching the adapter
# schema's "never serialize an absent field as null" rule for the events this
# process writes back.
type CommandLine record {|
    string? id = ();
    string? op = ();
    int? protocolVersion = ();
    string? path = ();
    json args = ();
    string? subscriptionId = ();
    string? token = ();
|};

# Per-run mutable state: the lazily-created `Client` and the subscriptions
# the controller currently has active. A plain mutable record, not isolated
# state - it is only ever touched by one strand at a time (the stdio loop, or
# one TCP connection's serialized callbacks), so it needs no lock at all.
type AdapterState record {|
    Client? clientBox = ();
    map<Subscription> subscriptions = {};
|};

# One serialized NDJSON writer shared by the command-handling strand and
# every subscription's relay strand, plus the per-subscription generation
# table that makes replacement, unsubscribe, and close all invalidate a stale
# relay before its acknowledgement is written - never after. This one *is*
# isolated state: relay strands genuinely run concurrently with command
# handling.
isolated class AdapterOutput {
    private boolean useTcp = false;
    private tcp:Caller? tcpCaller = ();
    private map<int> generations = {};
    private map<int> active = {};
    private boolean closed = false;

    isolated function initTcp(tcp:Caller caller) {
        lock {
            self.useTcp = true;
            self.tcpCaller = caller;
        }
    }

    isolated function send(json event) {
        json & readonly frozen = event.cloneReadOnly();
        lock {
            if self.closed {
                return;
            }
            emitLine(self.useTcp, self.tcpCaller, frozen);
        }
    }

    isolated function activateAndAck(string subscriptionId, string? commandId) returns int {
        int generation;
        lock {
            int previous = self.generations[subscriptionId] ?: 0;
            generation = previous + 1;
            self.generations[subscriptionId] = generation;
            self.active[subscriptionId] = generation;
            if !self.closed {
                emitLine(self.useTcp, self.tcpCaller, ackEvent(commandId));
            }
        }
        return generation;
    }

    isolated function invalidate(string subscriptionId) {
        lock {
            int previous = self.generations[subscriptionId] ?: 0;
            self.generations[subscriptionId] = previous + 1;
            int removedGeneration = self.active.remove(subscriptionId);
        }
    }

    isolated function invalidateAndAck(string subscriptionId, string? commandId) {
        lock {
            int previous = self.generations[subscriptionId] ?: 0;
            self.generations[subscriptionId] = previous + 1;
            int removedGeneration = self.active.remove(subscriptionId);
            if !self.closed {
                emitLine(self.useTcp, self.tcpCaller, ackEvent(commandId));
            }
        }
    }

    isolated function relay(string subscriptionId, int generation, json event) returns boolean {
        json & readonly frozen = event.cloneReadOnly();
        lock {
            int? current = self.active[subscriptionId];
            if self.closed || current != generation {
                return false;
            }
            emitLine(self.useTcp, self.tcpCaller, frozen);
            return true;
        }
    }

    isolated function close(string? commandId) {
        lock {
            if self.closed {
                return;
            }
            self.active = {};
            self.closed = true;
            emitLine(self.useTcp, self.tcpCaller, closedEvent(commandId));
        }
    }
}

// Ballerina's `lock` is not reentrant: a helper method called from inside a
// `lock` block must itself require no lock, which means it cannot read `self`
// at all. This is a free function for exactly that reason - every call site
// above already extracted `useTcp`/`tcpCaller` from `self` as part of the
// same lock that guards the state change the write must stay atomic with.
isolated function emitLine(boolean useTcp, tcp:Caller? caller, json event) {
    string line = event.toJsonString() + "\n";
    if useTcp {
        if caller is tcp:Caller {
            tcp:Error? writeErr = caller->writeBytes(line.toBytes());
        }
    } else {
        io:print(line);
    }
}

# A tiny cross-strand latch: `main`'s poll loop (in TCP mode) needs to learn,
# from a strand it does not own, that the one accepted controller connection
# has finished. Kept separate from `AdapterOutput` because it protects a
# single boolean, not the writer.
isolated class Signal {
    private boolean done = false;

    isolated function markDone() {
        lock {
            self.done = true;
        }
    }

    isolated function isDone() returns boolean {
        lock {
            return self.done;
        }
    }
}

isolated function readyEvent(string? id) returns json =>
    {'type: "ready", id, protocolVersion: 1, language: "ballerina", implementation: "native-ballerina-0.1.0", runtime: BALLERINA_RUNTIME};

isolated function ackEvent(string? id) returns json => id is string ? {'type: "ack", id} : {'type: "ack"};

isolated function closedEvent(string? id) returns json => id is string ? {'type: "closed", id} : {'type: "closed"};

function resultEvent(string? id, json value, string[] logs) returns json {
    map<json> event = {'type: "result", value};
    if id is string {
        event["id"] = id;
    }
    if logs.length() > 0 {
        event["logs"] = logs;
    }
    return event;
}

function failureEvent(string? id, string? subscriptionId, ConvexError err) returns json {
    string eventType = subscriptionId is string ? "subscription" : "error";
    map<json> event = {'type: eventType};
    if id is string {
        event["id"] = id;
    }
    if subscriptionId is string {
        event["subscriptionId"] = subscriptionId;
    }
    string name;
    string[] logs;
    if err is FunctionError {
        name = "FunctionError";
        logs = err.detail().logs;
    } else if err is ProtocolError {
        name = "ProtocolError";
        logs = err.detail().logs;
    } else if err is TransportError {
        name = "TransportError";
        logs = err.detail().logs;
    } else {
        name = "Error";
        logs = err.detail().logs;
    }
    map<json> detail = {name, message: err.message()};
    if err is FunctionError {
        detail["data"] = err.detail().data;
    }
    event["error"] = detail;
    if logs.length() > 0 {
        event["logs"] = logs;
    }
    return event;
}

function subscriptionEvent(string subscriptionId, Update update) returns json {
    ConvexError? err = update.err;
    if err is ConvexError {
        return failureEvent((), subscriptionId, err);
    }
    map<json> event = {'type: "subscription", subscriptionId, value: update.value};
    if update.logs.length() > 0 {
        event["logs"] = update.logs;
    }
    return event;
}

function relayUpdates(AdapterOutput output, string subscriptionId, int generation, Mailbox mailbox) {
    while true {
        Update|ClosedError|TransportError next = mailbox.recvTimeout(60.0);
        if next is Update {
            json event = subscriptionEvent(subscriptionId, next);
            boolean stillActive = output.relay(subscriptionId, generation, event);
            if !stillActive {
                return;
            }
        } else {
            // Either the mailbox closed (subscription removed/replaced) or a
            // long idle period passed with nothing to deliver; either way this
            // relay strand has nothing further to do.
            return;
        }
    }
}

function clientOrCreate(AdapterState state) returns Client|ConvexError {
    Client? existing = state.clientBox;
    if existing is Client {
        return existing;
    }
    string url = os:getEnv("CONVEX_URL");
    if url.length() == 0 {
        return error ProtocolError("CONVEX_URL is required", logs = []);
    }
    Client|ConvexError created = new Client(url);
    if created is Client {
        state.clientBox = created;
    }
    return created;
}

# Decodes and executes exactly one NDJSON command line, writing whatever
# response(s) it produces through `output`. Returns `true` when the command
# was `close`, so both call sites (the stdio loop and the TCP byte
# assembler) know to stop reading further lines.
function handleCommandLine(string line, AdapterOutput output, AdapterState state) returns boolean {
    CommandLine|error command = line.fromJsonStringWithType();
    if command is error {
        output.send(failureEvent((), (), error ProtocolError("invalid adapter command: " + command.message(), logs = [])));
        return false;
    }
    string? commandId = command.id;
    string operation = command.op ?: "";
    json args = command.args;

    if operation == "hello" && command.protocolVersion == 1 {
        output.send(readyEvent(commandId));
    } else if operation == "query" || operation == "mutation" || operation == "action" {
        Client|ConvexError clientResult = clientOrCreate(state);
        if clientResult is ConvexError {
            output.send(failureEvent(commandId, (), clientResult));
        } else {
            string path = command.path ?: "";
            CallResult|ConvexError result = operation == "query" ? clientResult.query(path, args) :
                operation == "mutation" ? clientResult.mutation(path, args) : clientResult.action(path, args);
            if result is CallResult {
                output.send(resultEvent(commandId, result.value, result.logs));
            } else {
                output.send(failureEvent(commandId, (), result));
            }
        }
    } else if operation == "setAuth" {
        Client|ConvexError clientResult = clientOrCreate(state);
        if clientResult is ConvexError {
            output.send(failureEvent(commandId, (), clientResult));
        } else {
            ConvexError? authError = clientResult.setAuth(command.token ?: "");
            if authError is ConvexError {
                output.send(failureEvent(commandId, (), authError));
            } else {
                output.send(ackEvent(commandId));
            }
        }
    } else if operation == "subscribe" {
        string subscriptionId = command.subscriptionId ?: "";
        Subscription? old = state.subscriptions[subscriptionId];
        if old is Subscription {
            Subscription removedSub = state.subscriptions.remove(subscriptionId);
            ConvexError? oldCloseErr = old.close();
            output.invalidate(subscriptionId);
        }
        Client|ConvexError clientResult = clientOrCreate(state);
        if clientResult is ConvexError {
            output.send(failureEvent(commandId, (), clientResult));
        } else {
            string path = command.path ?: "";
            Subscription|ConvexError subscribeResult = clientResult.subscribe(path, args);
            if subscribeResult is ConvexError {
                output.send(failureEvent(commandId, (), subscribeResult));
            } else {
                state.subscriptions[subscriptionId] = subscribeResult;
                Mailbox mailbox = subscribeResult.updates();
                int generation = output.activateAndAck(subscriptionId, commandId);
                future<()> relayTask = start relayUpdates(output, subscriptionId, generation, mailbox);
            }
        }
    } else if operation == "unsubscribe" {
        string subscriptionId = command.subscriptionId ?: "";
        Subscription? existing = state.subscriptions[subscriptionId];
        if existing is Subscription {
            Subscription removedSub = state.subscriptions.remove(subscriptionId);
            ConvexError? existingCloseErr = existing.close();
        }
        output.invalidateAndAck(subscriptionId, commandId);
    } else if operation == "debugDisconnect" {
        Client|ConvexError clientResult = clientOrCreate(state);
        if clientResult is ConvexError {
            output.send(failureEvent(commandId, (), clientResult));
        } else {
            ConvexError? disconnectError = clientResult.debugDisconnectForAdapter();
            if disconnectError is ConvexError {
                output.send(failureEvent(commandId, (), disconnectError));
            } else {
                output.send(ackEvent(commandId));
            }
        }
    } else if operation == "close" {
        finishState(state);
        output.close(commandId);
        return true;
    } else {
        output.send(failureEvent(commandId, (), error ProtocolError("unknown operation", logs = [])));
    }
    return false;
}

function finishState(AdapterState state) {
    foreach Subscription subscription in state.subscriptions {
        ConvexError? subCloseErr = subscription.close();
    }
    state.subscriptions = {};
    Client? finalClient = state.clientBox;
    if finalClient is Client {
        ConvexError? clientCloseErr = finalClient.close();
    }
}

function runStdioAdapter() returns error? {
    // `ballerina/io` has no dedicated stdin channel type, and its interactive
    // `readln()` throws an uncaught native exception (not a catchable
    // Ballerina error) and then hangs the process instead of returning
    // cleanly at EOF when stdin is a pipe rather than a terminal - fatal for
    // a test harness that closes its write end without sending `close`.
    // `/dev/stdin` opened as an ordinary file gives the same well-tested,
    // EOF-safe line stream every other file read in this ecosystem gets.
    io:ReadableByteChannel stdin = check io:openReadableFile("/dev/stdin");
    io:ReadableCharacterChannel reader = new (stdin, "UTF-8");
    stream<string, io:Error?> lines = check reader.lineStream();
    AdapterOutput output = new;
    AdapterState state = {};
    boolean closedByCommand = false;
    error? iterationError = lines.forEach(function(string line) {
        if closedByCommand || line.trim().length() == 0 {
            return;
        }
        boolean stop = handleCommandLine(line, output, state);
        if stop {
            closedByCommand = true;
        }
    });
    if iterationError is error {
        return iterationError;
    }
    if !closedByCommand {
        finishState(state);
    }
}

# `ballerina/tcp` delivers raw bytes, not lines, so this assembles them into
# newline-delimited commands and runs each one through `handleCommandLine` -
# the exact path stdio mode uses. A plain (non-isolated) class: `onBytes` is
# only ever invoked for one connection's traffic, one call at a time, so
# `state` and `carry` need no lock, matching this repository's other
# hand-rolled clients' single-owner-strand designs.
service class LineHandler {
    *tcp:ConnectionService;
    private final AdapterOutput output;
    private final Signal signal;
    private AdapterState state = {};
    private string carry = "";

    function init(AdapterOutput output, Signal signal) {
        self.output = output;
        self.signal = signal;
    }

    remote function onBytes(readonly & byte[] data) returns byte[]? {
        string|error chunk = string:fromBytes(data);
        if chunk is error {
            return ();
        }
        self.carry = self.carry + chunk;
        string[] lines = re `\n`.split(self.carry);
        int completeCount = lines.length() - 1;
        self.carry = lines[completeCount];
        foreach int index in 0 ..< completeCount {
            string line = lines[index];
            if line.trim().length() > 0 {
                boolean stop = handleCommandLine(line, self.output, self.state);
                if stop {
                    self.signal.markDone();
                }
            }
        }
        return ();
    }

    remote function onError(tcp:Error err) {
        finishState(self.state);
        self.signal.markDone();
    }

    remote function onClose() {
        finishState(self.state);
        self.signal.markDone();
    }
}

service class Acceptor {
    *tcp:Service;
    private final AdapterOutput output;
    private final Signal signal;

    function init(AdapterOutput output, Signal signal) {
        self.output = output;
        self.signal = signal;
    }

    remote function onConnect(tcp:Caller caller) returns tcp:ConnectionService {
        self.output.initTcp(caller);
        return new LineHandler(self.output, self.signal);
    }
}

function runTcpAdapter(string listenAddress) returns error? {
    int colon = <int>listenAddress.lastIndexOf(":");
    string host = listenAddress.substring(0, colon);
    int port = check int:fromString(listenAddress.substring(colon + 1));
    AdapterOutput output = new;
    Signal signal = new;
    tcp:Listener adapterListener = check new (port, localHost = host);
    check adapterListener.attach(new Acceptor(output, signal), "adapter");
    check adapterListener.'start();
    while !signal.isDone() {
        runtime:sleep(0.05);
    }
    return ();
}

public function main() returns error? {
    string listenAddress = os:getEnv("ADAPTER_LISTEN");
    if listenAddress.length() > 0 {
        check runTcpAdapter(listenAddress);
    } else {
        check runStdioAdapter();
    }
}
