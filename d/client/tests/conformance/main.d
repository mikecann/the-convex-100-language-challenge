/** Test-only NDJSON adapter protocol v1.
 *
 * The adapter calls the native D client for every operation. A single output
 * gate owns subscription generations and each physical write, so a dequeued
 * stale event cannot cross replacement, unsubscribe, or close acknowledgement.
 */
module main;

import convex : ConvexClient, ConvexError, ConvexResult, ConvexSubscription,
    LiveUpdate, adapterDebugDisconnect;
import core.stdc.errno : EAGAIN, EINTR, errno;
import core.sync.mutex : Mutex;
import core.sys.posix.fcntl : F_GETFL, F_SETFL, O_NONBLOCK, fcntl;
import core.sys.posix.poll : POLLIN, POLLOUT, poll, pollfd;
import core.sys.posix.signal : SIG_IGN, SIGPIPE, signal;
import core.sys.posix.sys.socket : SHUT_RDWR, shutdown;
import core.sys.posix.unistd : close, pipe, read, write;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.ascii : isDigit;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.stdio : stderr;
import std.string : lastIndexOf;

enum runtimeName = "ldc-1.40.0";
enum maxInputLineBytes = 2 * 1024 * 1024;
enum maxOutputLineBytes = 3 * 1024 * 1024;
enum outputDeadlineMs = 500;
enum maxSubscriptions = 16;

private class Output
{
    private int descriptor;
    private bool socketTransport;
    private Mutex mutex;
    private ulong[string] generations;
    private ulong[string] active;
    private bool closed;

    this(int descriptor, bool socketTransport)
    {
        this.descriptor = descriptor;
        this.socketTransport = socketTransport;
        mutex = new Mutex();
        setNonblocking(descriptor);
    }

    bool send(JSONValue event)
    {
        synchronized (mutex)
            return writeLocked(event);
    }

    ulong activateAndAck(string subscriptionId, string commandId)
    {
        synchronized (mutex)
        {
            auto generation = generations.get(subscriptionId, 0) + 1;
            generations[subscriptionId] = generation;
            active[subscriptionId] = generation;
            writeLocked(simpleEvent(commandId, "ack"));
            return generation;
        }
    }

    void invalidate(string subscriptionId)
    {
        synchronized (mutex)
        {
            generations[subscriptionId] = generations.get(subscriptionId, 0) + 1;
            active.remove(subscriptionId);
        }
    }

    void invalidateAll()
    {
        synchronized (mutex)
        {
            foreach (subscriptionId; active.keys)
                generations[subscriptionId] = generations.get(subscriptionId, 0) + 1;
            active.clear();
        }
    }

    bool relay(string subscriptionId, ulong generation, JSONValue event)
    {
        synchronized (mutex)
        {
            if (closed || active.get(subscriptionId, 0) != generation)
                return false;
            return writeLocked(event);
        }
    }

    bool isActive(string subscriptionId, ulong generation)
    {
        synchronized (mutex)
            return !closed && active.get(subscriptionId, 0) == generation;
    }

    void acknowledge(string commandId)
    {
        synchronized (mutex)
            writeLocked(simpleEvent(commandId, "ack"));
    }

    void finish(string commandId)
    {
        synchronized (mutex)
        {
            if (closed)
                return;
            active.clear();
            writeLocked(simpleEvent(commandId, "closed"));
            closed = true;
        }
    }

    bool isClosed()
    {
        synchronized (mutex)
            return closed;
    }

    private bool writeLocked(JSONValue event)
    {
        if (closed)
            return false;
        auto wire = event.toString() ~ "\n";
        if (wire.length > maxOutputLineBytes)
        {
            failTransportLocked();
            return false;
        }
        /* The one encoded line remains charged and reachable until its final
         * byte is written. Other relays retain only their already bounded
         * LiveUpdate while waiting for this gate. */
        size_t offset;
        auto deadline = monotonicMilliseconds() + outputDeadlineMs;
        while (offset < wire.length)
        {
            auto remaining = deadline - monotonicMilliseconds();
            if (remaining <= 0)
            {
                failTransportLocked();
                return false;
            }
            pollfd entry;
            entry.fd = descriptor;
            entry.events = POLLOUT;
            auto ready = poll(&entry, 1, cast(int) remaining);
            if (ready < 0 && errno == EINTR)
                continue;
            if (ready <= 0)
            {
                failTransportLocked();
                return false;
            }
            auto written = write(descriptor, wire.ptr + offset, wire.length - offset);
            if (written < 0 && (errno == EAGAIN || errno == EINTR))
                continue;
            if (written <= 0)
            {
                failTransportLocked();
                return false;
            }
            offset += cast(size_t) written;
        }
        return true;
    }

    private void failTransportLocked()
    {
        closed = true;
        active.clear();
        if (socketTransport)
            shutdown(descriptor, SHUT_RDWR);
    }
}

private class Relay
{
    ConvexSubscription subscription;
    Thread worker;
    string subscriptionId;
    ulong generation;

    this(ConvexSubscription subscription, string subscriptionId, ulong generation,
            Output output, int delayMs)
    {
        this.subscription = subscription;
        this.subscriptionId = subscriptionId;
        this.generation = generation;
        worker = new Thread({
            for (;;)
            {
                auto update = subscription.next(100);
                if (update is null)
                {
                    if (!output.isActive(subscriptionId, generation))
                        return;
                    continue;
                }
                if (delayMs > 0)
                    Thread.sleep(delayMs.msecs);
                if (!output.relay(subscriptionId, generation,
                    subscriptionEvent(subscriptionId, update)))
                    return;
            }
        });
        worker.name = "convex-d-adapter-relay";
        worker.start();
    }

    void stop()
    {
        try
            subscription.close();
        catch (ConvexError)
        {
        }
        worker.join();
    }
}

version (AdapterUnitTest)
{
    void main()
    {
    }
}
else
    void main()
{
    import std.process : environment;

    signal(SIGPIPE, SIG_IGN);
    auto listen = environment.get("ADAPTER_LISTEN", "");
    if (listen.length == 0)
    {
        setNonblocking(0);
        serve(0, new Output(1, false));
        return;
    }
    auto colon = listen.lastIndexOf(':');
    if (colon <= 0 || colon == listen.length - 1)
        throw new Exception("ADAPTER_LISTEN must be host:port");
    auto host = listen[0 .. colon];
    auto portText = listen[colon + 1 .. $];
    foreach (digit; portText)
        if (!digit.isDigit)
            throw new Exception("ADAPTER_LISTEN has invalid port");
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress(host, to!ushort(portText)));
    listener.listen(1);
    auto peer = listener.accept();
    auto descriptor = cast(int) peer.handle;
    setNonblocking(descriptor);
    serve(descriptor, new Output(descriptor, true));
    peer.close();
    listener.close();
}

private void serve(int input, Output output)
{
    auto client = cast(ConvexClient) null;
    Relay[string] relays;
    string pending;
    bool done;
    import std.process : environment;

    auto relayDelay = environment.get("ADAPTER_TEST_RELAY_DELAY_MS", "0").to!int;
    ubyte[16_384] bytes;
    while (!done && !output.isClosed())
    {
        pollfd entry;
        entry.fd = input;
        entry.events = POLLIN;
        auto ready = poll(&entry, 1, 50);
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready < 0)
            break;
        if (ready == 0)
            continue;
        auto received = read(input, bytes.ptr, bytes.length);
        if (received < 0 && (errno == EAGAIN || errno == EINTR))
            continue;
        if (received <= 0)
            break;
        pending ~= cast(string) bytes[0 .. received].idup;
        for (;;)
        {
            long newline = -1;
            foreach (index, octet; pending)
                if (octet == '\n')
                {
                    newline = cast(long) index;
                    break;
                }
            if (newline < 0)
                break;
            auto line = pending[0 .. newline];
            if (line.length > 0 && line[$ - 1] == '\r')
                line = line[0 .. $ - 1];
            pending = pending[newline + 1 .. $];
            handle(client, relays, line, output, relayDelay, done);
            if (done || output.isClosed())
                break;
        }
        if (pending.length > maxInputLineBytes)
        {
            output.send(errorEvent("", "ProtocolError", "adapter input line exceeds 2 MiB"));
            break;
        }
    }
    output.invalidateAll();
    foreach (relay; relays.byValue())
        relay.stop();
    if (client !is null)
        try
            client.close();
        catch (ConvexError)
        {
        }
}

private void handle(ref ConvexClient client, ref Relay[string] relays, string line,
        Output output, int relayDelay, ref bool done)
{
    JSONValue command;
    try
    {
        command = parseJSON(line);
    }
    catch (Exception)
    {
        output.send(errorEvent("", "ProtocolError", "malformed adapter command"));
        return;
    }
    if (command.type != JSONType.object || !hasString(command, "op"))
    {
        output.send(errorEvent(fieldString(command, "id"), "ProtocolError",
                "malformed adapter command"));
        return;
    }
    auto id = fieldString(command, "id");
    auto op = fieldString(command, "op");
    if (op == "hello")
    {
        if (!hasInteger(command, "protocolVersion")
                || command.object["protocolVersion"].integer != 1)
        {
            output.send(errorEvent(id, "ProtocolError", "unsupported adapter protocol version"));
        }
        else
        {
            JSONValue[string] ready;
            ready["protocolVersion"] = JSONValue(1L);
            ready["id"] = JSONValue(id);
            ready["type"] = JSONValue("ready");
            ready["language"] = JSONValue("d");
            ready["implementation"] = JSONValue("native-d-libcurl-rfc6455");
            ready["runtime"] = JSONValue(runtimeName);
            output.send(JSONValue(ready));
        }
        return;
    }
    if (op == "close")
    {
        output.invalidateAll();
        foreach (relay; relays.byValue())
            relay.stop();
        relays.clear();
        if (client !is null)
            try
                client.close();
            catch (ConvexError error)
            {
                output.send(convexErrorEvent(id, error));
                done = true;
                return;
            }
        output.finish(id);
        done = true;
        return;
    }
    if (op == "setAuth")
    {
        try
        {
            client = ensureClient(client);
            if (!hasString(command, "token"))
                throw new ConvexError("ProtocolError", "setAuth needs token");
            client.setAuth(fieldString(command, "token"));
            output.acknowledge(id);
        }
        catch (ConvexError error)
        {
            output.send(convexErrorEvent(id, error));
        }
        return;
    }
    if (op == "query" || op == "mutation" || op == "action")
    {
        try
        {
            if (!hasString(command, "path") || !("args" in command.object))
                throw new ConvexError("ProtocolError", "adapter call needs path and args");
            client = ensureClient(client);
            ConvexResult result;
            if (op == "query")
                result = client.query(fieldString(command, "path"), command.object["args"]);
            else if (op == "mutation")
                result = client.mutation(fieldString(command, "path"), command.object["args"]);
            else
                result = client.action(fieldString(command, "path"), command.object["args"]);
            JSONValue[string] event;
            event["id"] = JSONValue(id);
            event["type"] = JSONValue("result");
            event["value"] = result.value;
            if (result.logs.length > 0)
                event["logs"] = strings(result.logs);
            output.send(JSONValue(event));
        }
        catch (ConvexError error)
        {
            output.send(convexErrorEvent(id, error));
        }
        return;
    }
    if (op == "subscribe")
    {
        auto subscriptionId = fieldString(command, "subscriptionId");
        output.invalidate(subscriptionId);
        if (subscriptionId in relays)
        {
            relays[subscriptionId].stop();
            relays.remove(subscriptionId);
        }
        try
        {
            if (subscriptionId.length == 0 || !hasString(command, "path")
                    || !("args" in command.object))
                throw new ConvexError("ProtocolError",
                        "subscribe needs subscriptionId, path, and args");
            if (relays.length >= maxSubscriptions)
                throw new ConvexError("ProtocolError", "adapter supports at most 16 subscriptions");
            client = ensureClient(client);
            auto subscription = client.subscribe(fieldString(command, "path"),
                    command.object["args"]);
            auto generation = output.activateAndAck(subscriptionId, id);
            relays[subscriptionId] = new Relay(subscription, subscriptionId,
                    generation, output, relayDelay);
        }
        catch (ConvexError error)
        {
            output.send(convexErrorEvent(id, error));
        }
        return;
    }
    if (op == "unsubscribe")
    {
        auto subscriptionId = fieldString(command, "subscriptionId");
        output.invalidate(subscriptionId);
        if (subscriptionId in relays)
        {
            relays[subscriptionId].stop();
            relays.remove(subscriptionId);
        }
        output.acknowledge(id);
        return;
    }
    if (op == "debugDisconnect")
    {
        try
        {
            client = ensureClient(client);
            adapterDebugDisconnect(client);
            output.acknowledge(id);
        }
        catch (ConvexError error)
        {
            output.send(convexErrorEvent(id, error));
        }
        return;
    }
    output.send(errorEvent(id, "ProtocolError", "unknown adapter operation"));
}

private ConvexClient ensureClient(ConvexClient client)
{
    if (client !is null)
        return client;
    import std.process : environment;

    auto url = environment.get("CONVEX_URL", "");
    if (url.length == 0)
        throw new ConvexError("ProtocolError", "CONVEX_URL is required");
    return new ConvexClient(url);
}

private JSONValue subscriptionEvent(string subscriptionId, LiveUpdate update)
{
    JSONValue[string] event;
    event["subscriptionId"] = JSONValue(subscriptionId);
    event["type"] = JSONValue("subscription");
    if (update.error !is null)
    {
        JSONValue[string] detail;
        detail["name"] = JSONValue(update.error.kind);
        detail["message"] = JSONValue(update.error.msg);
        if (update.error.data.type != JSONType.null_)
            detail["data"] = update.error.data;
        event["error"] = JSONValue(detail);
    }
    else if (update.hasValue)
    {
        event["value"] = update.value;
    }
    else
    {
        JSONValue[string] detail;
        detail["name"] = JSONValue("ProtocolError");
        detail["message"] = JSONValue("Live success omitted value");
        event["error"] = JSONValue(detail);
    }
    if (update.logs.length > 0)
        event["logs"] = strings(update.logs);
    return JSONValue(event);
}

private bool hasString(JSONValue value, string key)
{
    return value.type == JSONType.object && key in value.object
        && value.object[key].type == JSONType.string;
}

private bool hasInteger(JSONValue value, string key)
{
    return value.type == JSONType.object && key in value.object
        && value.object[key].type == JSONType.integer;
}

private string fieldString(JSONValue value, string key)
{
    return hasString(value, key) ? value.object[key].str : "";
}

private JSONValue strings(string[] lines)
{
    JSONValue[] values;
    foreach (line; lines)
        values ~= JSONValue(line);
    return JSONValue(values);
}

private JSONValue simpleEvent(string id, string kind)
{
    JSONValue[string] event;
    if (id.length > 0)
        event["id"] = JSONValue(id);
    event["type"] = JSONValue(kind);
    return JSONValue(event);
}

private JSONValue errorEvent(string id, string kind, string message)
{
    return errorEvent(id, kind, message, JSONValue.init, []);
}

private JSONValue convexErrorEvent(string id, ConvexError error)
{
    return errorEvent(id, error.kind, error.msg, error.data, error.logs);
}

private JSONValue errorEvent(string id, string kind, string message, JSONValue data, string[] logs)
{
    JSONValue[string] detail;
    detail["name"] = JSONValue(kind);
    detail["message"] = JSONValue(message);
    if (data.type != JSONType.null_)
        detail["data"] = data;
    JSONValue[string] event;
    if (id.length > 0)
        event["id"] = JSONValue(id);
    event["type"] = JSONValue("error");
    event["error"] = JSONValue(detail);
    if (logs.length > 0)
        event["logs"] = strings(logs);
    return JSONValue(event);
}

private void setNonblocking(int descriptor)
{
    auto flags = fcntl(descriptor, F_GETFL, 0);
    if (flags >= 0)
        fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

private long monotonicMilliseconds()
{
    return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1_000);
}

version (AdapterUnitTest) unittest
{
    int[2] descriptors;
    assert(pipe(descriptors) == 0);
    scope (exit)
    {
        close(descriptors[0]);
        close(descriptors[1]);
    }
    auto output = new Output(descriptors[1], false);
    auto generation = output.activateAndAck("same", "first");
    output.invalidate("same");
    output.acknowledge("unsubscribe");
    auto stale = subscriptionEvent("same", new LiveUpdate());
    assert(!output.relay("same", generation, stale));
}

version (AdapterUnitTest) unittest
{
    int[2] descriptors;
    assert(pipe(descriptors) == 0);
    scope (exit)
    {
        close(descriptors[0]);
        close(descriptors[1]);
    }
    auto output = new Output(descriptors[1], false);
    auto payload = new char[1024 * 1024];
    payload[] = 'x';
    JSONValue[string] event;
    event["type"] = JSONValue("result");
    event["id"] = JSONValue("blocked");
    event["value"] = JSONValue(payload.idup);
    auto started = monotonicMilliseconds();
    assert(!output.send(JSONValue(event)));
    assert(output.isClosed());
    assert(monotonicMilliseconds() - started < 1_500);
}
