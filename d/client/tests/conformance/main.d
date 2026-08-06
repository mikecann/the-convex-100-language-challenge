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
import std.string : indexOf, lastIndexOf;

enum runtimeName = "ldc-1.40.0";
enum maxInputLineBytes = 2 * 1024 * 1024;
enum maxInputQueueBytes = 4 * 1024 * 1024;
enum maxInputQueueLines = 32;
enum maxOutputLineBytes = 3 * 1024 * 1024;
enum outputDeadlineMs = 500;
enum maxSubscriptions = 16;

/** The reader may see close while the command owner is waiting for a Live Add
 * barrier. Recording it here lets that reader cancel a stalled WebSocket dial
 * without executing any other adapter command out of order. */
private class AdapterSession
{
    private Mutex mutex;
    private ConvexClient client;
    private bool closeRequested;
    private ConvexError closeError;

    this()
    {
        mutex = new Mutex();
    }

    ConvexClient ensureClient()
    {
        import std.process : environment;

        synchronized (mutex)
        {
            if (closeRequested)
                throw new ConvexError("Error", "Convex client is closed");
            if (client is null)
            {
                auto url = environment.get("CONVEX_URL", "");
                if (url.length == 0)
                    throw new ConvexError("ProtocolError", "CONVEX_URL is required");
                client = new ConvexClient(url);
            }
            return client;
        }
    }

    void requestClose()
    {
        ConvexClient current;
        synchronized (mutex)
        {
            closeRequested = true;
            current = client;
        }
        if (current !is null)
        {
            try
                current.close();
            catch (ConvexError error)
                synchronized (mutex)
                    closeError = error;
        }
    }

    ConvexError closeFailure()
    {
        synchronized (mutex)
            return closeError;
    }
}

/** Read and frame NDJSON independently of command execution. Only close has an
 * early side effect, and that side effect is limited to cancelling transport. */
private class CommandReader
{
    private int descriptor;
    private AdapterSession session;
    private Mutex mutex;
    private Thread worker;
    private string[] lines;
    private size_t queuedBytes;
    private bool stopped;
    private bool finished;
    private bool oversized;

    this(int descriptor, AdapterSession session)
    {
        this.descriptor = descriptor;
        this.session = session;
        mutex = new Mutex();
        worker = new Thread(&readLoop);
        worker.name = "convex-d-adapter-input";
        worker.start();
    }

    bool next(ref string line, int timeoutMs)
    {
        auto deadline = monotonicMilliseconds() + timeoutMs;
        for (;;)
        {
            synchronized (mutex)
            {
                if (lines.length > 0)
                {
                    line = lines[0];
                    lines = lines[1 .. $];
                    queuedBytes -= line.length + 1;
                    return true;
                }
                if (finished)
                    return false;
            }
            if (monotonicMilliseconds() >= deadline)
                return false;
            Thread.sleep(5.msecs);
        }
    }

    bool isFinished()
    {
        synchronized (mutex)
            return finished && lines.length == 0;
    }

    bool inputWasOversized()
    {
        synchronized (mutex)
            return oversized;
    }

    void stop()
    {
        synchronized (mutex)
            stopped = true;
        worker.join();
    }

    private void readLoop()
    {
        string pending;
        ubyte[16_384] bytes;
        readMore: for (;;)
        {
            synchronized (mutex)
                if (stopped)
                    break;
            pollfd entry;
            entry.fd = descriptor;
            entry.events = POLLIN;
            auto ready = poll(&entry, 1, 50);
            if (ready < 0 && errno == EINTR)
                continue;
            if (ready < 0)
                break;
            if (ready == 0)
                continue;
            auto received = read(descriptor, bytes.ptr, bytes.length);
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
                if (line.length > maxInputLineBytes)
                {
                    synchronized (mutex)
                        oversized = true;
                    break readMore;
                }
                if (isCloseCommand(line))
                    session.requestClose();
                if (!enqueue(line.idup))
                    break readMore;
            }
            if (pending.length > maxInputLineBytes)
            {
                synchronized (mutex)
                    oversized = true;
                break;
            }
        }
        synchronized (mutex)
            finished = true;
    }

    private bool enqueue(string line)
    {
        for (;;)
        {
            synchronized (mutex)
            {
                if (stopped)
                    return false;
                if (lines.length < maxInputQueueLines
                        && queuedBytes + line.length + 1 <= maxInputQueueBytes)
                {
                    lines ~= line;
                    queuedBytes += line.length + 1;
                    return true;
                }
            }
            Thread.sleep(5.msecs);
        }
    }
}

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
    Thread worker;
    string subscriptionId;
    ulong generation;
    private LiveUpdate delegate(int) nextUpdate;
    private void delegate(LiveUpdate) releaseUpdate;
    private void delegate() closeSource;
    private void delegate() afterDequeue;

    this(ConvexSubscription subscription, string subscriptionId, ulong generation,
            Output output, int delayMs)
    {
        nextUpdate = (int timeoutMs) => subscription.nextRetained(timeoutMs);
        releaseUpdate = (LiveUpdate update) => subscription.releaseRetained(update);
        closeSource = () => subscription.close();
        start(subscriptionId, generation, output, delayMs);
    }

    version (AdapterUnitTest) this(LiveUpdate delegate(int) nextUpdate, void delegate(LiveUpdate) releaseUpdate,
            void delegate() closeSource, void delegate() afterDequeue,
            string subscriptionId, ulong generation, Output output)
    {
        this.nextUpdate = nextUpdate;
        this.releaseUpdate = releaseUpdate;
        this.closeSource = closeSource;
        this.afterDequeue = afterDequeue;
        start(subscriptionId, generation, output, 0);
    }

    private void start(string subscriptionId, ulong generation, Output output, int delayMs)
    {
        this.subscriptionId = subscriptionId;
        this.generation = generation;
        worker = new Thread({
            for (;;)
            {
                auto update = nextUpdate(100);
                if (update is null)
                {
                    if (!output.isActive(subscriptionId, generation))
                        return;
                    continue;
                }
                try
                {
                    if (afterDequeue !is null)
                        afterDequeue();
                    if (delayMs > 0)
                        Thread.sleep(delayMs.msecs);
                    if (!output.relay(subscriptionId, generation,
                        subscriptionEvent(subscriptionId, update)))
                        return;
                }
                finally
                {
                    /* The Live owner keeps this value charged while it waits
                     * for the physical NDJSON write or is rejected as stale. */
                    releaseUpdate(update);
                }
            }
        });
        worker.name = "convex-d-adapter-relay";
        worker.start();
    }

    void stop()
    {
        try
            closeSource();
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
    auto session = new AdapterSession();
    auto reader = new CommandReader(input, session);
    Relay[string] relays;
    bool done;
    import std.process : environment;

    auto relayDelay = environment.get("ADAPTER_TEST_RELAY_DELAY_MS", "0").to!int;
    while (!done && !output.isClosed())
    {
        string line;
        if (reader.next(line, 50))
        {
            handle(session, relays, line, output, relayDelay, done);
            continue;
        }
        if (reader.isFinished())
            break;
    }
    if (reader.inputWasOversized() && !output.isClosed())
        output.send(errorEvent("", "ProtocolError", "adapter input line exceeds 2 MiB"));
    output.invalidateAll();
    foreach (relay; relays.byValue())
        relay.stop();
    session.requestClose();
    reader.stop();
}

private void handle(AdapterSession session, ref Relay[string] relays, string line,
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
    if (command.type != JSONType.object)
    {
        output.send(errorEvent("", "ProtocolError", "malformed adapter command"));
        return;
    }
    auto id = fieldString(command, "id");
    if (!hasIdentifier(command, "id"))
    {
        /* An invalid ID cannot be echoed because that would make the error
         * event itself fail the adapter schema. */
        output.send(errorEvent("", "ProtocolError", "adapter command id must be 1 to 128 bytes"));
        return;
    }
    if (!hasString(command, "op"))
    {
        output.send(errorEvent(id, "ProtocolError", "malformed adapter command"));
        return;
    }
    auto op = fieldString(command, "op");
    if (op == "hello")
    {
        if (!hasOnlyFields(command, ["protocolVersion", "id", "op"]) || !hasInteger(command,
                "protocolVersion") || command.object["protocolVersion"].integer != 1)
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
        if (!hasOnlyFields(command, ["id", "op"]))
        {
            output.send(errorEvent(id, "ProtocolError", "malformed close command"));
            return;
        }
        output.invalidateAll();
        foreach (relay; relays.byValue())
            relay.stop();
        relays.clear();
        session.requestClose();
        auto closeError = session.closeFailure();
        if (closeError !is null)
        {
            output.send(convexErrorEvent(id, closeError));
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
            if (!hasOnlyFields(command, ["id", "op", "token"]) || !hasString(command, "token"))
                throw new ConvexError("ProtocolError", "setAuth needs token");
            auto client = session.ensureClient();
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
            if (!hasOnlyFields(command, ["id", "op", "path", "args"])
                    || !hasString(command, "path") || fieldString(command, "path").length < 3
                    || !("args" in command.object) || command.object["args"].type != JSONType
                        .object)
                throw new ConvexError("ProtocolError", "adapter call needs path and args");
            auto client = session.ensureClient();
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
        if (!hasIdentifier(command, "subscriptionId"))
        {
            output.send(errorEvent(id, "ProtocolError", "subscriptionId must be 1 to 128 bytes"));
            return;
        }
        output.invalidate(subscriptionId);
        if (subscriptionId in relays)
        {
            relays[subscriptionId].stop();
            relays.remove(subscriptionId);
        }
        try
        {
            if (!hasOnlyFields(command, [
                "id", "op", "subscriptionId", "path", "args"
            ]) || !hasString(command, "path") || !("args" in command.object)
                    || command.object["args"].type != JSONType.object)
                throw new ConvexError("ProtocolError",
                        "subscribe needs subscriptionId, path, and args");
            if (relays.length >= maxSubscriptions)
                throw new ConvexError("ProtocolError", "adapter supports at most 16 subscriptions");
            auto client = session.ensureClient();
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
        if (!hasOnlyFields(command, [
            "id", "op", "subscriptionId", "path", "args"
        ]) || !hasIdentifier(command, "subscriptionId") || ("path" in command.object
                    && !hasString(command, "path")) || ("args" in command.object
                    && command.object["args"].type != JSONType.object))
        {
            output.send(errorEvent(id, "ProtocolError", "malformed unsubscribe command"));
            return;
        }
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
            if (!hasOnlyFields(command, ["id", "op"]))
                throw new ConvexError("ProtocolError", "malformed debugDisconnect command");
            auto client = session.ensureClient();
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

private bool isCloseCommand(string line)
{
    try
    {
        auto command = parseJSON(line);
        return command.type == JSONType.object && hasString(command, "op")
            && command.object["op"].str == "close" && hasIdentifier(command,
                    "id") && hasOnlyFields(command, ["id", "op"]);
    }
    catch (Exception)
    {
        return false;
    }
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
        if (update.error.hasData)
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

private bool hasIdentifier(JSONValue value, string key)
{
    if (!hasString(value, key))
        return false;
    auto identifier = value.object[key].str;
    return identifier.length >= 1 && identifier.length <= 128;
}

private bool hasOnlyFields(JSONValue value, string[] allowed)
{
    if (value.type != JSONType.object)
        return false;
    foreach (key; value.object.keys)
    {
        bool known;
        foreach (candidate; allowed)
        {
            if (key == candidate)
            {
                known = true;
                break;
            }
        }
        if (!known)
            return false;
    }
    return true;
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
    return errorEvent(id, kind, message, JSONValue.init, [], false);
}

private JSONValue convexErrorEvent(string id, ConvexError error)
{
    return errorEvent(id, error.kind, error.msg, error.data, error.logs, error.hasData);
}

private JSONValue errorEvent(string id, string kind, string message,
        JSONValue data, string[] logs, bool hasData)
{
    JSONValue[string] detail;
    detail["name"] = JSONValue(kind);
    detail["message"] = JSONValue(message);
    if (hasData)
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

version (AdapterUnitTest) unittest
{
    auto explicitNull = new ConvexError("FunctionError", "null payload",
            JSONValue(null), [], true);
    auto encoded = convexErrorEvent("http", explicitNull);
    assert("data" in encoded.object["error"].object);
    assert(encoded.object["error"].object["data"].type == JSONType.null_);

    auto absent = convexErrorEvent("http", new ConvexError("FunctionError", "absent"));
    assert("data" !in absent.object["error"].object);

    auto update = new LiveUpdate();
    update.error = explicitNull;
    auto subscription = subscriptionEvent("live", update);
    assert("data" in subscription.object["error"].object);
    assert(subscription.object["error"].object["data"].type == JSONType.null_);
}

version (AdapterUnitTest) unittest
{
    import core.time : msecs;
    import std.process : environment;
    import std.socket : InternetAddress, TcpSocket;
    import std.string : indexOf;

    enum port = 18151;
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(1);
    auto stalled = new Thread({
        scope (exit)
            listener.close();
        auto peer = listener.accept();
        scope (exit)
            peer.close();
        ubyte[4096] request;
        assert(peer.receive(request) > 0);
        ubyte[32] untilClosed;
        try
            while (peer.receive(untilClosed) > 0)
            {
            }
                catch (Exception)
                {
                }
    });
    stalled.start();

    auto previousUrl = environment.get("CONVEX_URL", "");
    environment["CONVEX_URL"] = "http://127.0.0.1:" ~ port.to!string;
    scope (exit)
    {
        if (previousUrl.length > 0)
            environment["CONVEX_URL"] = previousUrl;
        else
            environment.remove("CONVEX_URL");
    }

    int[2] input;
    int[2] result;
    assert(pipe(input) == 0 && pipe(result) == 0);
    setNonblocking(input[0]);
    auto output = new Output(result[1], false);
    auto adapter = new Thread({ serve(input[0], output); });
    adapter.start();

    auto subscribe = `{"id":"subscribe","op":"subscribe","subscriptionId":"s","path":"demo:state","args":{}}`
        ~ "\n";
    assert(write(input[1], subscribe.ptr, subscribe.length) == subscribe.length);
    Thread.sleep(250.msecs);
    auto started = monotonicMilliseconds();
    auto closeCommand = `{"id":"close","op":"close"}` ~ "\n";
    assert(write(input[1], closeCommand.ptr, closeCommand.length) == closeCommand.length);
    close(input[1]);
    adapter.join();
    assert(monotonicMilliseconds() - started < 1_500);
    close(input[0]);
    close(result[1]);

    string response;
    ubyte[4096] chunk;
    for (;;)
    {
        auto received = read(result[0], chunk.ptr, chunk.length);
        if (received <= 0)
            break;
        response ~= cast(string) chunk[0 .. received].idup;
    }
    close(result[0]);
    assert(response.indexOf(`"id":"subscribe"`) >= 0);
    assert(response.indexOf(`"id":"close","type":"closed"`) >= 0);
    stalled.join();
}

version (AdapterUnitTest) unittest
{
    foreach (replacement; [false, true])
    {
        int[2] descriptors;
        assert(pipe(descriptors) == 0);
        auto output = new Output(descriptors[1], false);
        auto oldGeneration = output.activateAndAck("same", "first");

        auto gate = new Mutex();
        bool dequeued;
        bool resume;
        bool supplied;
        size_t releases;
        auto update = new LiveUpdate();
        update.hasValue = true;
        update.value = JSONValue(["count": JSONValue(1L)]);
        auto relay = new Relay((int) {
            if (!supplied)
            {
                supplied = true;
                return update;
            }
            return null;
        }, (LiveUpdate released) { releases++; }, () {}, () {
            synchronized (gate)
                dequeued = true;
            for (;;)
            {
                synchronized (gate)
                    if (resume)
                        break;
                Thread.sleep(5.msecs);
            }
        }, "same", oldGeneration, output);

        auto deadline = monotonicMilliseconds() + 1_000;
        for (;;)
        {
            synchronized (gate)
                if (dequeued)
                    break;
            assert(monotonicMilliseconds() < deadline);
            Thread.sleep(5.msecs);
        }
        output.invalidate("same");
        if (replacement)
            output.activateAndAck("same", "replacement");
        else
            output.acknowledge("unsubscribe");
        synchronized (gate)
            resume = true;
        relay.stop();
        assert(releases == 1);

        close(descriptors[1]);
        string response;
        ubyte[4096] bytes;
        for (;;)
        {
            auto received = read(descriptors[0], bytes.ptr, bytes.length);
            if (received <= 0)
                break;
            response ~= cast(string) bytes[0 .. received].idup;
        }
        close(descriptors[0]);
        assert(response.indexOf(`"id":"first"`) >= 0);
        assert(response.indexOf(replacement ? `"id":"replacement"` : `"id":"unsubscribe"`) >= 0);
        assert(response.indexOf(`"subscriptionId":"same"`) < 0);
    }
}
