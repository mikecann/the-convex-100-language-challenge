/** Test-only NDJSON adapter protocol v1. The client itself is HTTP-only, so
 * Live operations fail explicitly rather than claiming a fake subscription. */
module main;

import convex : ConvexClient, ConvexError, ConvexResult;
import std.ascii : isDigit;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : Address, InternetAddress, Socket, SocketType, TcpSocket;
import std.stdio : stderr, stdin, stdout, writefln;
import std.string : chomp, indexOf, lastIndexOf;

enum runtimeName = "ldc-1.30.0";

alias Emit = void delegate(JSONValue);

void main() {
    import std.process : environment;

    const listen = environment.get("ADAPTER_LISTEN", "");
    if (listen.length == 0) {
        serveStdio();
        return;
    }
    serveTcp(listen);
}

private void serveStdio() {
    auto client = cast(ConvexClient) null;
    bool done;
    foreach (raw; stdin.byLine()) {
        handle(client, raw.chomp.idup, (JSONValue event) { writefln("%s", event.toString()); }, done);
        if (done)
            return;
    }
}

private void serveTcp(string address) {
    const colon = address.lastIndexOf(':');
    if (colon <= 0 || colon == address.length - 1)
        throw new Exception("ADAPTER_LISTEN must be host:port");
    const host = address[0 .. colon];
    const portText = address[colon + 1 .. $];
    foreach (digit; portText) if (!digit.isDigit) throw new Exception("ADAPTER_LISTEN has invalid port");
    const port = to!ushort(portText);
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress(host, port));
    listener.listen(1);
    auto peer = listener.accept();
    scope(exit) { peer.close(); listener.close(); }

    auto client = cast(ConvexClient) null;
    string pending;
    bool done;
    ubyte[4096] bytes;
    while (!done) {
        const received = peer.receive(bytes);
        if (received <= 0)
            return;
        pending ~= cast(string) bytes[0 .. received].idup;
        while (true) {
            const newline = pending.indexOf('\n');
            if (newline < 0)
                break;
            const line = pending[0 .. newline].chomp;
            pending = pending[newline + 1 .. $];
            handle(client, line, (JSONValue event) {
                const wire = event.toString() ~ "\n";
                peer.send(cast(const(ubyte)[]) wire);
            }, done);
            if (done)
                return;
        }
        if (pending.length > 2 * 1024 * 1024)
            throw new Exception("adapter input line exceeds 2 MiB");
    }
}

private void handle(ref ConvexClient client, string line, Emit emit, ref bool done) {
    JSONValue command;
    try command = parseJSON(line); catch (Exception error) {
        emit(errorEvent("", "ProtocolError", "malformed adapter command"));
        return;
    }
    if (command.type != JSONType.object || !hasString(command, "op")) {
        emit(errorEvent(fieldString(command, "id"), "ProtocolError", "malformed adapter command"));
        return;
    }
    const id = fieldString(command, "id");
    const op = fieldString(command, "op");
    if (op == "hello") {
        if (!hasInteger(command, "protocolVersion") || command.object["protocolVersion"].integer != 1)
            emit(errorEvent(id, "ProtocolError", "unsupported adapter protocol version"));
        else {
            JSONValue[string] ready;
            ready["protocolVersion"] = JSONValue(1L);
            ready["id"] = JSONValue(id);
            ready["type"] = JSONValue("ready");
            ready["language"] = JSONValue("d");
            ready["implementation"] = JSONValue("native-d-phobos-libcurl-http");
            ready["runtime"] = JSONValue(runtimeName);
            emit(JSONValue(ready));
        }
        return;
    }
    if (op == "close") {
        if (client !is null) client.close();
        emit(simpleEvent(id, "closed"));
        done = true;
        return;
    }
    if (op == "subscribe" || op == "unsubscribe" || op == "debugDisconnect") {
        emit(errorEvent(id, "ProtocolError", "D Live support is not implemented"));
        return;
    }
    if (op == "setAuth") {
        try {
            client = ensureClient(client);
            client.setAuth(fieldString(command, "token"));
            emit(simpleEvent(id, "ack"));
        } catch (ConvexError error) emit(convexErrorEvent(id, error));
        return;
    }
    if (op == "query" || op == "mutation" || op == "action") {
        try {
            if (!hasString(command, "path") || !("args" in command.object))
                throw new ConvexError("ProtocolError", "adapter call needs path and args");
            client = ensureClient(client);
            ConvexResult result;
            switch (op) {
                case "query": result = client.query(fieldString(command, "path"), command.object["args"]); break;
                case "mutation": result = client.mutation(fieldString(command, "path"), command.object["args"]); break;
                case "action": result = client.action(fieldString(command, "path"), command.object["args"]); break;
                default: assert(0);
            }
            JSONValue[string] event;
            event["id"] = JSONValue(id);
            event["type"] = JSONValue("result");
            event["value"] = result.value;
            if (result.logs.length > 0) event["logs"] = strings(result.logs);
            emit(JSONValue(event));
        } catch (ConvexError error) emit(convexErrorEvent(id, error));
        return;
    }
    emit(errorEvent(id, "ProtocolError", "unknown adapter operation"));
}

private ConvexClient ensureClient(ConvexClient client) {
    if (client !is null) return client;
    import std.process : environment;
    const url = environment.get("CONVEX_URL", "");
    if (url.length == 0) throw new ConvexError("ProtocolError", "CONVEX_URL is required");
    return new ConvexClient(url);
}

private bool hasString(JSONValue value, string key) {
    return value.type == JSONType.object && key in value.object && value.object[key].type == JSONType.string;
}
private bool hasInteger(JSONValue value, string key) {
    return value.type == JSONType.object && key in value.object && value.object[key].type == JSONType.integer;
}
private string fieldString(JSONValue value, string key) { return hasString(value, key) ? value.object[key].str : ""; }
private JSONValue strings(string[] lines) { JSONValue[] values; foreach (line; lines) values ~= JSONValue(line); return JSONValue(values); }
private JSONValue simpleEvent(string id, string kind) { JSONValue[string] event; event["id"] = JSONValue(id); event["type"] = JSONValue(kind); return JSONValue(event); }
private JSONValue errorEvent(string id, string kind, string message) { return errorEvent(id, kind, message, JSONValue.init, []); }
private JSONValue convexErrorEvent(string id, ConvexError error) { return errorEvent(id, error.kind, error.msg, error.data, error.logs); }
private JSONValue errorEvent(string id, string kind, string message, JSONValue data, string[] logs) {
    JSONValue[string] detail; detail["name"] = JSONValue(kind); detail["message"] = JSONValue(message);
    if (data.type != JSONType.null_) detail["data"] = data;
    JSONValue[string] event; if (id.length > 0) event["id"] = JSONValue(id); event["type"] = JSONValue("error"); event["error"] = JSONValue(detail);
    if (logs.length > 0) event["logs"] = strings(logs);
    return JSONValue(event);
}
