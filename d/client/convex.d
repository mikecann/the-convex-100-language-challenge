/**
 * A small native D Convex client for documented HTTP calls and Live queries.
 *
 * Phobos and libcurl provide JSON, HTTP, TLS, and WebSocket transport. The
 * Convex envelopes, sync state machine, reconnects, and delivery semantics are
 * implemented here in D rather than delegated to another Convex SDK.
 */
module convex;

import core.stdc.config : c_long;
import core.sync.mutex : Mutex;
import core.sys.posix.poll : POLLIN, POLLOUT, poll, pollfd;
import core.thread : Thread;
import core.time : msecs;
import etc.c.curl : CURL, CURLcode, CURL_SOCKET_BAD, CurlError, CurlOption,
    curl_easy_cleanup, curl_easy_getinfo, curl_easy_init,
    curl_easy_perform, curl_easy_recv, curl_easy_send, curl_easy_setopt, curl_easy_strerror,
    curl_slist, curl_slist_append, curl_slist_free_all, curl_socket_t;
import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.base64 : Base64;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.string : indexOf, stripRight;
import std.string : fromStringz, toStringz;
import std.uuid : randomUUID;
import std.utf : validate;

enum clientVersion = "d-0.1.0";
enum maxResponseBytes = 2 * 1024 * 1024;
enum maxLiveMessageBytes = 2 * 1024 * 1024;
enum liveQueueCapacity = 16;
enum liveQueueBudgetBytes = 8 * 1024 * 1024;
enum liveSendTimeoutMs = 500;
enum liveCommandTimeoutMs = 12_000;
enum initialTimestamp = "AAAAAAAAAAA=";

private extern (C) int RAND_bytes(ubyte* buffer, int length);

struct ConvexResult
{
    JSONValue value;
    string[] logs;
}

class ConvexError : Exception
{
    string kind;
    bool hasData;
    JSONValue data;
    string[] logs;

    this(string kind, string message, JSONValue data = JSONValue.init,
            string[] logs = [], bool hasData = false)
    {
        super(message);
        this.kind = kind;
        this.hasData = hasData;
        this.data = data;
        this.logs = logs;
    }
}

/** A Live item has either a value (which may itself be JSON null) or an error. */
class LiveUpdate
{
    bool hasValue;
    JSONValue value;
    ConvexError error;
    string[] logs;

    private ulong serial;
    private size_t retainedBytes;
    private bool retainedByAdapter;
}

/** Keep the public API compact while preserving the error details supplied by
 * Convex. A client may replace or clear its bearer token between calls. */
class ConvexClient
{
    private string deployment;
    private string token;
    private bool closed;
    private Mutex stateMutex;
    private LiveManager live;

    this(string deploymentUrl)
    {
        deployment = normalizeDeployment(deploymentUrl);
        stateMutex = new Mutex();
    }

    void setAuth(string bearerToken)
    {
        synchronized (stateMutex)
        {
            ensureOpenLocked();
            token = bearerToken;
        }
    }

    ConvexResult query(string path, JSONValue args)
    {
        return call("query", path, args);
    }

    ConvexResult mutation(string path, JSONValue args)
    {
        return call("mutation", path, args);
    }

    ConvexResult action(string path, JSONValue args)
    {
        return call("action", path, args);
    }

    /** Start a real `/api/sync` WebSocket query. The returned handle owns a
     * newest-16 mailbox and can be closed independently of the client. */
    ConvexSubscription subscribe(string path, JSONValue args)
    {
        if (path.length == 0 || args.type != JSONType.object)
            throw new ConvexError("ProtocolError",
                    "Live query path and object arguments are required");
        LiveManager manager;
        synchronized (stateMutex)
        {
            ensureOpenLocked();
            if (live is null)
                live = new LiveManager(deployment, clientVersion);
            manager = live;
        }
        return manager.add(path, args);
    }

    void close(int timeoutMs = 2_000)
    {
        LiveManager manager;
        synchronized (stateMutex)
        {
            if (closed)
                return;
            closed = true;
            token = "";
            manager = live;
        }
        if (manager !is null)
            manager.close(timeoutMs);
    }

    private ConvexResult call(string operation, string path, JSONValue args)
    {
        string auth;
        synchronized (stateMutex)
        {
            ensureOpenLocked();
            auth = token;
        }
        if (path.length == 0)
            throw new ConvexError("ProtocolError", "Convex function path is required");
        if (args.type != JSONType.object)
            throw new ConvexError("ProtocolError", "Convex arguments must be a JSON object");

        JSONValue[string] request;
        request["path"] = JSONValue(path);
        request["args"] = args;
        request["format"] = JSONValue("json");
        return decodeResponse(operation,
                requestJson(deployment ~ "/api/" ~ operation, JSONValue(request), auth));
    }

    private void ensureOpenLocked()
    {
        if (closed)
            throw new ConvexError("Error", "Convex client is closed");
    }

    private string requestJson(string endpoint, JSONValue body, string auth)
    {
        auto encoded = body.toString();
        auto http = HTTP();
        http.url = endpoint;
        http.addRequestHeader("Accept", "application/json");
        http.addRequestHeader("Convex-Client", clientVersion);
        if (auth.length > 0)
            http.addRequestHeader("Authorization", "Bearer " ~ auth);
        http.setPostData(encoded, "application/json");

        ubyte[] response;
        http.onReceive = (ubyte[] bytes) {
            if (response.length + bytes.length > maxResponseBytes)
                return cast(size_t) 0;
            response ~= bytes;
            return bytes.length;
        };
        try
        {
            http.perform();
        }
        catch (Exception error)
        {
            throw new ConvexError("TransportError", error.msg);
        }
        return cast(string) response.idup;
    }
}

/** Decode is separate from transport so its success, function-error, malformed
 * response, and log handling can be checked without a network fixture. */
ConvexResult decodeResponse(string operation, string responseBody)
{
    JSONValue response;
    try
    {
        response = parseJSON(responseBody);
    }
    catch (Exception error)
    {
        throw new ConvexError("ProtocolError", "HTTP response was not valid Convex JSON");
    }
    if (response.type != JSONType.object || "status" !in response.object)
        throw new ConvexError("ProtocolError", "HTTP response had an unknown status");

    auto status = response.object["status"];
    if (status.type != JSONType.string)
        throw new ConvexError("ProtocolError", "HTTP response had an unknown status");
    auto logs = responseLogs(response);
    if (status.str == "success")
    {
        if ("value" !in response.object)
            throw new ConvexError("ProtocolError", "HTTP success response omitted value");
        return ConvexResult(response.object["value"], logs);
    }
    if (status.str == "error")
    {
        bool hasData = ("errorData" in response.object) !is null;
        JSONValue data = hasData ? response.object["errorData"] : JSONValue.init;
        string message = "errorMessage" in response.object && response.object["errorMessage"].type == JSONType.string
            ? response.object["errorMessage"].str : "Convex function failed";
        throw new ConvexError("FunctionError", message, data, logs, hasData);
    }
    throw new ConvexError("ProtocolError", "HTTP response had an unknown status");
}

private string[] responseLogs(JSONValue response)
{
    string[] logs;
    if ("logLines" !in response.object || response.object["logLines"].type != JSONType.array)
        return logs;
    foreach (line; response.object["logLines"].array)
    {
        if (line.type == JSONType.string)
            logs ~= line.str;
    }
    return logs;
}

private string normalizeDeployment(string value)
{
    auto trimmed = value.stripRight("/");
    if (!(trimmed.startsWith("http://") || trimmed.startsWith("https://")))
        throw new ConvexError("ProtocolError", "Convex deployment URL must use http or https");
    auto afterScheme = trimmed.indexOf("://") + 3;
    if (afterScheme >= trimmed.length || trimmed[afterScheme .. $].length == 0
            || trimmed[afterScheme .. $].indexOf('@') >= 0)
        throw new ConvexError("ProtocolError",
                "Convex deployment URL must include a host and no credentials");
    return trimmed;
}

private enum curlInfoActiveSocket = 0x500000 + 44;
private enum curlOptionWsOptions = 320;
private enum curlWsRawMode = 1;

/** A subscription handle never touches the socket. It communicates with the
 * one Live owner and reads only its bounded mailbox. */
class ConvexSubscription
{
    private LiveManager manager;
    private SubscriptionState state;

    private this(LiveManager manager, SubscriptionState state)
    {
        this.manager = manager;
        this.state = state;
    }

    /** Return the next value or error, or null when the deadline expires or
     * after the subscription has been closed. */
    LiveUpdate next(int timeoutMs = -1)
    {
        return manager.next(state, timeoutMs);
    }

    version (ConvexAdapter) LiveUpdate nextRetained(int timeoutMs = -1)
    {
        return manager.next(state, timeoutMs, true);
    }

    version (ConvexAdapter) void releaseRetained(LiveUpdate update)
    {
        manager.releaseRetained(update);
    }

    void close(int timeoutMs = 2_000)
    {
        manager.remove(state, timeoutMs);
    }
}

private class SubscriptionState
{
    uint queryId;
    string path;
    JSONValue args;
    bool active = true;
    bool addPending = true;
    bool addDone;
    bool removePending;
    bool removeDone;
    bool rehydrating;
    bool hasLastValue;
    JSONValue lastValue;
    LiveUpdate[] queue;
}

private struct StateVersion
{
    uint querySet;
    uint identity;
    ulong timestamp;
    string encodedTimestamp;
}

private class PendingModification
{
    string type;
    uint queryId;
    bool hasValue;
    JSONValue value;
    bool hasData;
    JSONValue data;
    string message;
    string[] logs;
}

private class LiveManager
{
    private string deployment;
    private string versionHeader;
    private Mutex mutex;
    private Thread worker;
    private SubscriptionState[uint] subscriptions;
    private uint nextQueryId;
    private uint querySetVersion;
    private StateVersion remoteVersion;
    private bool hasMaximumTimestamp;
    private ulong maximumTimestamp;
    private string maximumTimestampEncoded;
    private uint connectionCount;
    private string lastCloseReason = "InitialConnect";
    private bool closing;
    private bool stopped;
    private bool debugRequested;
    private ulong debugGeneration;
    private ulong debugCompleted;
    private CURL* socket;
    private bool connected;
    private ulong updateSerial;
    private size_t queuedBytes;
    private bool fragmentedText;
    private ubyte[] fragmentedPayload;

    this(string deployment, string versionHeader)
    {
        this.deployment = deployment;
        this.versionHeader = versionHeader;
        mutex = new Mutex();
        remoteVersion = StateVersion(0, 0, 0, initialTimestamp);
        worker = new Thread(&ownerLoop);
        worker.name = "convex-d-live-owner";
        worker.start();
    }

    ConvexSubscription add(string path, JSONValue args)
    {
        auto state = new SubscriptionState();
        state.path = path;
        state.args = args;
        synchronized (mutex)
        {
            if (closing || stopped)
                throw new ConvexError("Error", "Convex client is closed");
            state.queryId = nextQueryId++;
            subscriptions[state.queryId] = state;
        }
        if (!waitUntil(() => state.addDone || !state.active || stopped, liveCommandTimeoutMs))
        {
            synchronized (mutex)
            {
                state.removePending = true;
            }
            throw new ConvexError("TransportError", "timed out installing Live query");
        }
        synchronized (mutex)
        {
            if (!state.addDone)
                throw new ConvexError("TransportError", "Live owner stopped before Add completed");
        }
        return new ConvexSubscription(this, state);
    }

    LiveUpdate next(SubscriptionState state, int timeoutMs, bool retainForAdapter = false)
    {
        StopWatch clock;
        clock.start();
        for (;;)
        {
            synchronized (mutex)
            {
                if (state.queue.length > 0)
                {
                    auto update = state.queue[0];
                    state.queue = state.queue[1 .. $];
                    update.retainedByAdapter = retainForAdapter;
                    if (!retainForAdapter)
                        queuedBytes -= update.retainedBytes;
                    return update;
                }
                if (!state.active || stopped)
                    return null;
            }
            if (timeoutMs >= 0 && clock.peek.total!"msecs" >= timeoutMs)
                return null;
            Thread.sleep(5.msecs);
        }
    }

    version (ConvexAdapter) void releaseRetained(LiveUpdate update)
    {
        if (update is null)
            return;
        synchronized (mutex)
        {
            if (update.retainedByAdapter)
            {
                update.retainedByAdapter = false;
                queuedBytes -= update.retainedBytes;
            }
        }
    }

    void remove(SubscriptionState state, int timeoutMs)
    {
        synchronized (mutex)
        {
            if (!state.active || state.removeDone)
                return;
            state.removePending = true;
            clearQueueLocked(state);
        }
        if (!waitUntil(() => state.removeDone || stopped, timeoutMs))
            throw new ConvexError("TransportError", "timed out completing Live Remove");
        synchronized (mutex)
        {
            if (!state.removeDone && stopped)
                throw new ConvexError("TransportError",
                        "client closed before Live Remove completed");
        }
    }

    void debugDisconnect(int timeoutMs = 2_000)
    {
        ulong generation;
        synchronized (mutex)
        {
            if (!connected || socket is null)
                throw new ConvexError("TransportError", "Live WebSocket is not connected");
            generation = ++debugGeneration;
            debugRequested = true;
        }
        if (!waitUntil(() => debugCompleted >= generation || stopped, timeoutMs))
            throw new ConvexError("TransportError", "timed out retiring Live WebSocket");
        synchronized (mutex)
        {
            if (debugCompleted < generation)
                throw new ConvexError("TransportError", "client closed during debug disconnect");
        }
    }

    void close(int timeoutMs)
    {
        synchronized (mutex)
        {
            if (stopped)
                return;
            closing = true;
            foreach (state; subscriptions.byValue())
            {
                state.active = false;
                state.removeDone = true;
                clearQueueLocked(state);
            }
        }
        if (!waitUntil(() => stopped, timeoutMs))
            throw new ConvexError("TransportError", "timed out waiting for Live owner to close");
        worker.join();
    }

    private bool waitUntil(scope bool delegate() predicate, int timeoutMs)
    {
        StopWatch clock;
        clock.start();
        for (;;)
        {
            synchronized (mutex)
            {
                if (predicate())
                    return true;
            }
            if (timeoutMs >= 0 && clock.peek.total!"msecs" >= timeoutMs)
                return false;
            Thread.sleep(5.msecs);
        }
    }

    private size_t activeCountLocked()
    {
        size_t count;
        foreach (state; subscriptions.byValue())
            if (state.active && !state.removePending)
                count++;
        return count;
    }

    private uint[] activeIdsLocked()
    {
        uint[] ids;
        foreach (id, state; subscriptions)
            if (state.active && !state.removePending)
                ids ~= id;
        ids.sort();
        return ids;
    }

    private void clearQueueLocked(SubscriptionState state)
    {
        foreach (update; state.queue)
            queuedBytes -= update.retainedBytes;
        state.queue = [];
    }

    private void enqueueLocked(SubscriptionState state, LiveUpdate update)
    {
        update.serial = ++updateSerial;
        update.retainedBytes = retainedSize(update);
        if (update.retainedBytes > maxLiveMessageBytes)
        {
            update = new LiveUpdate();
            update.error = new ConvexError("ProtocolError", "Live update exceeds 2 MiB");
            update.serial = ++updateSerial;
            update.retainedBytes = retainedSize(update);
        }
        while (state.queue.length >= liveQueueCapacity)
            evictFrontLocked(state);
        state.queue ~= update;
        queuedBytes += update.retainedBytes;
        while (queuedBytes > liveQueueBudgetBytes && evictGlobalOldestLocked())
        {
        }
    }

    private void evictFrontLocked(SubscriptionState state)
    {
        if (state.queue.length == 0)
            return;
        queuedBytes -= state.queue[0].retainedBytes;
        state.queue = state.queue[1 .. $];
    }

    private bool evictGlobalOldestLocked()
    {
        SubscriptionState oldest;
        ulong serial = ulong.max;
        foreach (state; subscriptions.byValue())
        {
            if (state.queue.length > 0 && state.queue[0].serial < serial)
            {
                serial = state.queue[0].serial;
                oldest = state;
            }
        }
        if (oldest is null)
            return false;
        evictFrontLocked(oldest);
        return true;
    }

    private size_t retainedSize(LiveUpdate update)
    {
        size_t size = 256;
        if (update.hasValue)
            size += update.value.toString().length;
        if (update.error !is null)
        {
            size += update.error.msg.length + update.error.kind.length;
            if (update.error.hasData)
                size += update.error.data.toString().length;
        }
        foreach (line; update.logs)
            size += line.length + 32;
        return size;
    }

    private void ownerLoop()
    {
        long reconnectAt;
        int backoff = 100;
        ubyte[] receiveBuffer;
        string reason;
        while (true)
        {
            synchronized (mutex)
            {
                if (closing)
                    break;
                if (debugRequested)
                {
                    debugRequested = false;
                    retireSocketLocked("DebugDisconnect");
                    debugCompleted = debugGeneration;
                    reconnectAt = monotonicMilliseconds() + 100;
                }
                if (socket is null)
                {
                    foreach (state; subscriptions.byValue())
                    {
                        if (state.removePending && !state.removeDone)
                        {
                            state.active = false;
                            state.removeDone = true;
                        }
                    }
                }
            }

            SubscriptionState pendingAdd;
            SubscriptionState pendingRemove;
            synchronized (mutex)
            {
                if (socket !is null)
                {
                    auto ids = subscriptions.keys.sort().array;
                    foreach (id; ids)
                    {
                        auto state = subscriptions[id];
                        if (state.active && state.addPending && !state.removePending)
                        {
                            pendingAdd = state;
                            break;
                        }
                    }
                    foreach (id; ids)
                    {
                        auto state = subscriptions[id];
                        if (state.removePending && !state.removeDone)
                        {
                            pendingRemove = state;
                            break;
                        }
                    }
                }
            }
            if (pendingAdd !is null)
            {
                JSONValue message;
                synchronized (mutex)
                    message = modifyMessageLocked([pendingAdd.queryId], false);
                if (sendJson(message, pendingAdd, false, reason))
                {
                    synchronized (mutex)
                    {
                        querySetVersion++;
                        pendingAdd.addPending = false;
                        pendingAdd.addDone = true;
                    }
                }
                else
                {
                    synchronized (mutex)
                        retireSocketLocked(reason);
                    reconnectAt = monotonicMilliseconds() + backoff;
                    backoff = nextBackoff(backoff);
                }
                continue;
            }
            if (pendingRemove !is null)
            {
                JSONValue message;
                synchronized (mutex)
                    message = modifyMessageLocked([pendingRemove.queryId], true);
                if (sendJson(message, pendingRemove, true, reason))
                {
                    synchronized (mutex)
                    {
                        querySetVersion++;
                        pendingRemove.active = false;
                        pendingRemove.removeDone = true;
                        clearQueueLocked(pendingRemove);
                    }
                }
                else
                {
                    synchronized (mutex)
                        retireSocketLocked(reason);
                    reconnectAt = monotonicMilliseconds() + backoff;
                    backoff = nextBackoff(backoff);
                }
                continue;
            }

            size_t active;
            bool hasSocket;
            synchronized (mutex)
            {
                active = activeCountLocked();
                hasSocket = socket !is null;
            }
            if (!hasSocket && active > 0 && monotonicMilliseconds() >= reconnectAt)
            {
                if (connectSocket(reason))
                {
                    /* A completed RFC6455 handshake is a healthy connection
                     * boundary, so later failures restart at the initial delay. */
                    backoff = 100;
                }
                else
                {
                    synchronized (mutex)
                    {
                        connectionCount++;
                        lastCloseReason = reason;
                    }
                    reconnectAt = monotonicMilliseconds() + backoff;
                    backoff = nextBackoff(backoff);
                }
                continue;
            }
            if (hasSocket)
            {
                auto result = receiveMessage(receiveBuffer, reason);
                if (result == 0 && waitSocket(POLLIN, 20) > 0)
                    result = receiveMessage(receiveBuffer, reason);
                if (result == 1)
                    backoff = 100;
                else if (result < 0)
                {
                    synchronized (mutex)
                    {
                        if (result == -2)
                            publishErrorLocked("ProtocolError", reason, false);
                        else if (!closing && !debugRequested)
                            publishErrorLocked("TransportError", reason, true);
                        retireSocketLocked(reason);
                    }
                    receiveBuffer = [];
                    reconnectAt = monotonicMilliseconds() + backoff;
                    backoff = nextBackoff(backoff);
                }
            }
            else
            {
                Thread.sleep(10.msecs);
            }
        }
        bool shouldClose;
        synchronized (mutex)
            shouldClose = socket !is null;
        if (shouldClose)
        {
            string ignored;
            sendFrame(8, [], null, true, ignored);
        }
        synchronized (mutex)
        {
            if (socket !is null)
                curl_easy_cleanup(socket);
            socket = null;
            connected = false;
            stopped = true;
        }
    }

    private bool connectSocket(ref string reason)
    {
        string url = deployment.startsWith("https://")
            ? "wss://" ~ deployment[8 .. $] ~ "/api/sync" : "ws://" ~ deployment[7 .. $]
            ~ "/api/sync";
        auto nextSocket = curl_easy_init();
        if (nextSocket is null)
        {
            reason = "could not create Live WebSocket";
            return false;
        }
        curl_slist* headers;
        auto header = "Convex-Client: " ~ versionHeader;
        headers = curl_slist_append(headers, header.toStringz());
        scope (exit)
            curl_slist_free_all(headers);
        curl_easy_setopt(nextSocket, CurlOption.url, url.toStringz());
        curl_easy_setopt(nextSocket, CurlOption.httpheader, headers);
        curl_easy_setopt(nextSocket, CurlOption.connect_only, cast(c_long) 2);
        curl_easy_setopt(nextSocket, CurlOption.timeout_ms, cast(c_long) 10_000);
        curl_easy_setopt(nextSocket, CurlOption.noprogress, cast(c_long) 0);
        curl_easy_setopt(nextSocket, CurlOption.progressfunction, &liveDialProgress);
        curl_easy_setopt(nextSocket, CurlOption.progressdata, cast(void*) this);
        curl_easy_setopt(nextSocket, cast(CurlOption) curlOptionWsOptions,
                cast(c_long) curlWsRawMode);
        auto code = curl_easy_perform(nextSocket);
        if (code != CurlError.ok)
        {
            reason = "live dial: " ~ curlError(code);
            curl_easy_cleanup(nextSocket);
            return false;
        }
        synchronized (mutex)
            socket = nextSocket;
        if (!sendJson(connectMessage(), null, false, reason))
        {
            synchronized (mutex)
            {
                curl_easy_cleanup(socket);
                socket = null;
            }
            return false;
        }

        uint[] ids;
        synchronized (mutex)
            ids = activeIdsLocked();
        if (ids.length > 0 && !sendJson(modifyMessageSnapshot(ids), null, false, reason))
        {
            synchronized (mutex)
            {
                curl_easy_cleanup(socket);
                socket = null;
            }
            return false;
        }
        synchronized (mutex)
        {
            querySetVersion = ids.length > 0 ? 1 : 0;
            foreach (id; ids)
            {
                auto state = subscriptions[id];
                state.addPending = false;
                state.addDone = true;
            }
            connected = true;
        }
        return true;
    }

    private bool shouldCancelDial()
    {
        synchronized (mutex)
            return closing;
    }

    private JSONValue connectMessage()
    {
        JSONValue[string] message;
        message["type"] = JSONValue("Connect");
        message["sessionId"] = JSONValue(randomUUID().toString());
        synchronized (mutex)
        {
            message["connectionCount"] = JSONValue(cast(long) connectionCount);
            message["lastCloseReason"] = JSONValue(lastCloseReason);
            if (hasMaximumTimestamp)
                message["maxObservedTimestamp"] = JSONValue(maximumTimestampEncoded);
        }
        message["clientTs"] = JSONValue(0L);
        return JSONValue(message);
    }

    private JSONValue modifyMessageSnapshot(uint[] ids)
    {
        synchronized (mutex)
            return modifyMessageLocked(ids, false);
    }

    private JSONValue modifyMessageLocked(uint[] ids, bool remove)
    {
        JSONValue[] modifications;
        foreach (id; ids)
        {
            auto state = subscriptions[id];
            JSONValue[string] modification;
            modification["type"] = JSONValue(remove ? "Remove" : "Add");
            modification["queryId"] = JSONValue(cast(long) id);
            if (!remove)
            {
                modification["udfPath"] = JSONValue(state.path);
                modification["args"] = JSONValue([state.args]);
            }
            modifications ~= JSONValue(modification);
        }
        JSONValue[string] message;
        message["type"] = JSONValue("ModifyQuerySet");
        message["baseVersion"] = JSONValue(cast(long) querySetVersion);
        message["newVersion"] = JSONValue(cast(long) querySetVersion + 1);
        message["modifications"] = JSONValue(modifications);
        return JSONValue(message);
    }

    private bool sendJson(JSONValue message, SubscriptionState state,
            bool removing, ref string reason)
    {
        auto encoded = message.toString();
        return sendFrame(1, cast(const(ubyte)[]) encoded, state, removing, reason);
    }

    /** Raw RFC6455 framing closes two parsed-mode gaps in libcurl 8.14.1:
     * non-minimal lengths and chunked Ping echo. libcurl still owns the HTTP
     * upgrade, TCP, TLS, and certificate verification. */
    private bool sendFrame(ubyte opcode, const(ubyte)[] payload,
            SubscriptionState state, bool removing, ref string reason)
    {
        ubyte[] frame;
        frame ~= cast(ubyte)(0x80 | opcode);
        if (payload.length < 126)
        {
            frame ~= cast(ubyte)(0x80 | payload.length);
        }
        else if (payload.length <= ushort.max)
        {
            frame ~= cast(ubyte)(0x80 | 126);
            frame ~= cast(ubyte)(payload.length >> 8);
            frame ~= cast(ubyte) payload.length;
        }
        else
        {
            frame ~= cast(ubyte)(0x80 | 127);
            foreach_reverse (index; 0 .. 8)
                frame ~= cast(ubyte)(cast(ulong) payload.length >> (index * 8));
        }
        /* RFC6455 requires a fresh unpredictable key for every client frame.
         * OpenSSL is already the pinned TLS provider behind libcurl. */
        ubyte[4] mask;
        if (RAND_bytes(mask.ptr, cast(int) mask.length) != 1)
        {
            reason = "could not obtain a WebSocket masking key";
            return false;
        }
        frame ~= mask[];
        auto payloadStart = frame.length;
        frame.length += payload.length;
        foreach (index, octet; payload)
            frame[payloadStart + index] = octet ^ mask[index % 4];

        size_t offset;
        auto deadline = monotonicMilliseconds() + liveSendTimeoutMs;
        while (offset < frame.length)
        {
            synchronized (mutex)
            {
                if ((closing && opcode != 8) || (state !is null && !removing && state.removePending))
                {
                    reason = "live write cancelled";
                    return false;
                }
            }
            auto remaining = deadline - monotonicMilliseconds();
            if (remaining <= 0)
            {
                reason = "live write timed out";
                return false;
            }
            size_t sent;
            CURLcode code;
            synchronized (mutex)
            {
                if (socket is null)
                {
                    reason = "Live WebSocket was retired";
                    return false;
                }
                code = curl_easy_send(socket, frame.ptr + offset, frame.length - offset, &sent);
            }
            if (code == CurlError.again || (code == CurlError.ok && sent == 0))
            {
                waitSocket(POLLOUT, cast(int)(remaining > 20 ? 20 : remaining));
                continue;
            }
            if (code != CurlError.ok)
            {
                reason = "live write: " ~ curlError(code);
                return false;
            }
            offset += sent;
        }
        return true;
    }

    /* 1 valid message/control traffic, 0 quiet/incomplete, -1 transport, -2
     * protocol. receiveBuffer persists across poll timeouts and frame chunks. */
    private int receiveMessage(ref ubyte[] receiveBuffer, ref string reason)
    {
        auto parsed = parseFrame(receiveBuffer, reason);
        if (parsed != 2)
            return parsed;
        ubyte[16_384] chunk;
        size_t received;
        CURLcode code;
        synchronized (mutex)
        {
            if (socket is null)
                return -1;
            code = curl_easy_recv(socket, chunk.ptr, chunk.length, &received);
        }
        if (code == CurlError.again)
            return 0;
        if (code != CurlError.ok)
        {
            reason = "live read: " ~ curlError(code);
            return -1;
        }
        if (received == 0)
        {
            reason = "WebSocket peer closed the transport";
            return -1;
        }
        receiveBuffer ~= chunk[0 .. received];
        parsed = parseFrame(receiveBuffer, reason);
        return parsed == 2 ? 0 : parsed;
    }

    /* Return 2 when another raw byte is needed, 1 for healthy traffic, 0 for
     * an incomplete fragmented message, -1 for Close, and -2 for protocol. */
    private int parseFrame(ref ubyte[] wire, ref string reason)
    {
        if (wire.length < 2)
            return 2;
        auto first = wire[0];
        auto second = wire[1];
        bool finalFrame = (first & 0x80) != 0;
        auto opcode = cast(ubyte)(first & 0x0f);
        if ((first & 0x70) != 0)
        {
            reason = "WebSocket frame used reserved bits";
            return -2;
        }
        if ((second & 0x80) != 0)
        {
            reason = "WebSocket server frame was masked";
            return -2;
        }
        if (opcode != 0 && opcode != 1 && opcode != 2 && opcode != 8 && opcode != 9 && opcode != 10)
        {
            reason = "WebSocket frame used an unknown opcode";
            return -2;
        }
        ulong length = second & 0x7f;
        size_t headerLength = 2;
        if (length == 126)
        {
            if (wire.length < 4)
                return 2;
            length = (cast(ulong) wire[2] << 8) | wire[3];
            headerLength = 4;
            if (length < 126)
            {
                reason = "WebSocket frame used a noncanonical length";
                return -2;
            }
        }
        else if (length == 127)
        {
            if (wire.length < 10)
                return 2;
            if ((wire[2] & 0x80) != 0)
            {
                reason = "WebSocket frame length exceeded uint63";
                return -2;
            }
            length = 0;
            foreach (octet; wire[2 .. 10])
                length = (length << 8) | octet;
            headerLength = 10;
            if (length <= ushort.max)
            {
                reason = "WebSocket frame used a noncanonical length";
                return -2;
            }
        }
        bool control = opcode >= 8;
        if (control && (!finalFrame || length > 125))
        {
            reason = "WebSocket control frame was fragmented or oversized";
            return -2;
        }
        if (length > maxLiveMessageBytes)
        {
            reason = "Live message exceeds 2 MiB";
            return -2;
        }
        if (wire.length < headerLength + length)
            return 2;
        auto payload = wire[headerLength .. headerLength + cast(size_t) length].dup;
        wire = wire[headerLength + cast(size_t) length .. $];
        if (opcode == 8)
        {
            if (payload.length == 1)
            {
                reason = "WebSocket Close frame omitted a complete status";
                return -2;
            }
            if (payload.length >= 2)
            {
                auto status = (cast(uint) payload[0] << 8) | payload[1];
                bool registered = status >= 1000 && status <= 1014
                    && status != 1004 && status != 1005 && status != 1006;
                bool privateUse = status >= 3000 && status <= 4999;
                if (!registered && !privateUse)
                {
                    reason = "WebSocket Close frame used an invalid status";
                    return -2;
                }
                try
                {
                    validate(cast(string) payload[2 .. $]);
                }
                catch (Exception error)
                {
                    reason = "WebSocket Close reason was not valid UTF-8: " ~ error.msg;
                    return -2;
                }
            }
            string replyFailure;
            /* Raw WebSocket mode makes this client responsible for the Close
             * handshake. Echo the validated payload before retiring the
             * transport, using the same bounded send path as every other
             * client frame. */
            if (!sendFrame(8, payload, null, true, replyFailure))
            {
                reason = "server closed Live WebSocket; Close reply failed: " ~ replyFailure;
                return -1;
            }
            reason = "server closed Live WebSocket";
            return -1;
        }
        if (opcode == 9)
        {
            if (!sendFrame(10, payload, null, true, reason))
                return -1;
            return 1;
        }
        if (opcode == 10)
            return 1;
        if (opcode == 2)
        {
            reason = "Live server sent a binary data message";
            return -2;
        }
        if (opcode == 0)
        {
            if (!fragmentedText)
            {
                reason = "WebSocket continuation had no leading text frame";
                return -2;
            }
            if (fragmentedPayload.length > maxLiveMessageBytes
                    || payload.length > maxLiveMessageBytes - fragmentedPayload.length)
            {
                reason = "Live message exceeds 2 MiB";
                return -2;
            }
            fragmentedPayload ~= payload;
            if (!finalFrame)
                return 0;
            payload = fragmentedPayload;
            fragmentedPayload = [];
            fragmentedText = false;
        }
        else if (!finalFrame)
        {
            if (fragmentedText)
            {
                reason = "WebSocket started a second fragmented message";
                return -2;
            }
            fragmentedText = true;
            fragmentedPayload = payload;
            return 0;
        }
        else if (fragmentedText)
        {
            reason = "WebSocket text frame interrupted a fragmented message";
            return -2;
        }

        string encoded = cast(string) payload;
        try
        {
            validate(encoded);
        }
        catch (Exception error)
        {
            reason = "Live message was not valid UTF-8: " ~ error.msg;
            return -2;
        }

        JSONValue message;
        try
        {
            message = parseJSON(encoded);
        }
        catch (Exception error)
        {
            reason = "decode server message: " ~ error.msg;
            return -2;
        }
        if (message.type != JSONType.object || !jsonString(message, "type"))
        {
            reason = "server message omitted type";
            return -2;
        }
        auto type = message.object["type"].str;
        if (type == "Transition")
            return handleTransition(message, reason) ? 1 : -2;
        if (type == "Ping")
            return 1;
        if (type == "MutationResponse" || type == "ActionResponse")
            return 1;
        reason = "unexpected server message " ~ type;
        if ("error" in message.object && message.object["error"].type == JSONType.string)
            reason ~= ": " ~ message.object["error"].str;
        return -2;
    }

    private bool handleTransition(JSONValue message, ref string reason)
    {
        StateVersion start;
        StateVersion end;
        if (!decodeStateVersion(message, "startVersion", start, reason) || !decodeStateVersion(message,
                "endVersion", end, reason) || !("modifications" in message.object)
                || message.object["modifications"].type != JSONType.array)
        {
            if (reason.length == 0)
                reason = "Transition omitted required version fields";
            return false;
        }
        synchronized (mutex)
        {
            if (start.querySet != remoteVersion.querySet
                    || start.identity != remoteVersion.identity
                    || start.timestamp != remoteVersion.timestamp)
            {
                reason = "Transition start version does not match local version";
                return false;
            }
        }
        if (end.querySet < start.querySet || end.identity < start.identity
                || end.timestamp < start.timestamp)
        {
            reason = "Transition end version moved backwards";
            return false;
        }

        PendingModification[uint] pending;
        foreach (modification; message.object["modifications"].array)
        {
            auto decoded = decodeModification(modification, reason);
            if (decoded is null)
                return false;
            pending[decoded.queryId] = decoded;
        }
        auto ids = pending.keys.sort().array;
        synchronized (mutex)
        {
            /* Recheck under the commit lock so another operation cannot make a
             * partially validated transition current. */
            if (start.querySet != remoteVersion.querySet
                    || start.identity != remoteVersion.identity
                    || start.timestamp != remoteVersion.timestamp)
            {
                reason = "Transition start version changed during validation";
                return false;
            }
            remoteVersion = end;
            if (!hasMaximumTimestamp || end.timestamp > maximumTimestamp)
            {
                hasMaximumTimestamp = true;
                maximumTimestamp = end.timestamp;
                maximumTimestampEncoded = end.encodedTimestamp;
            }
            foreach (id; ids)
            {
                if (id !in subscriptions)
                    continue;
                auto state = subscriptions[id];
                auto modification = pending[id];
                if (!state.active || state.removePending || modification.type == "QueryRemoved")
                    continue;
                auto update = new LiveUpdate();
                update.logs = modification.logs;
                if (modification.type == "QueryUpdated")
                {
                    bool unchanged = state.hasLastValue && state.lastValue == modification.value;
                    bool suppress = state.rehydrating && unchanged;
                    state.lastValue = modification.value;
                    state.hasLastValue = true;
                    state.rehydrating = false;
                    if (suppress)
                        continue;
                    update.hasValue = true;
                    update.value = modification.value;
                }
                else
                {
                    state.hasLastValue = false;
                    state.rehydrating = false;
                    auto data = modification.hasData ? modification.data : JSONValue.init;
                    update.error = new ConvexError("FunctionError", modification.message,
                            data, modification.logs, modification.hasData);
                }
                enqueueLocked(state, update);
            }
        }
        return true;
    }

    private PendingModification decodeModification(JSONValue value, ref string reason)
    {
        if (value.type != JSONType.object || !jsonString(value, "type")
                || !jsonUint(value, "queryId"))
        {
            reason = "Transition modification omitted type or queryId";
            return null;
        }
        auto type = value.object["type"].str;
        if (type != "QueryUpdated" && type != "QueryFailed" && type != "QueryRemoved")
        {
            reason = "unknown Transition modification " ~ type;
            return null;
        }
        auto decoded = new PendingModification();
        decoded.type = type;
        decoded.queryId = cast(uint) value.object["queryId"].integer;
        if ("logLines" in value.object)
        {
            if (value.object["logLines"].type != JSONType.array)
            {
                reason = "Transition modification has invalid logLines";
                return null;
            }
            foreach (line; value.object["logLines"].array)
            {
                if (line.type != JSONType.string)
                {
                    reason = "Transition modification has invalid logLines";
                    return null;
                }
                decoded.logs ~= line.str;
            }
        }
        if (type == "QueryUpdated")
        {
            if (!("value" in value.object))
            {
                reason = "QueryUpdated omitted value";
                return null;
            }
            decoded.hasValue = true;
            decoded.value = value.object["value"];
        }
        else if (type == "QueryFailed")
        {
            if (!jsonString(value, "errorMessage"))
            {
                reason = "QueryFailed omitted errorMessage";
                return null;
            }
            decoded.message = value.object["errorMessage"].str;
            if ("errorData" in value.object)
            {
                decoded.hasData = true;
                decoded.data = value.object["errorData"];
            }
        }
        return decoded;
    }

    private bool decodeStateVersion(JSONValue root, string name,
            ref StateVersion output, ref string reason)
    {
        if (!(name in root.object) || root.object[name].type != JSONType.object)
        {
            reason = "Transition omitted " ~ name;
            return false;
        }
        auto value = root.object[name];
        if (!jsonUint(value, "querySet") || !jsonUint(value, "identity")
                || !jsonString(value, "ts"))
        {
            reason = "Transition has invalid " ~ name;
            return false;
        }
        ulong timestamp;
        if (!decodeTimestamp(value.object["ts"].str, timestamp))
        {
            reason = "Transition has noncanonical timestamp";
            return false;
        }
        output = StateVersion(cast(uint) value.object["querySet"].integer,
                cast(uint) value.object["identity"].integer, timestamp, value.object["ts"].str);
        return true;
    }

    private void publishErrorLocked(string kind, string message, bool establishedOnly)
    {
        foreach (state; subscriptions.byValue())
        {
            if (!state.active || state.removePending || (establishedOnly && state.addPending))
                continue;
            auto update = new LiveUpdate();
            update.error = new ConvexError(kind, message);
            enqueueLocked(state, update);
        }
    }

    private void retireSocketLocked(string reason)
    {
        if (socket !is null)
        {
            curl_easy_cleanup(socket);
            socket = null;
        }
        connected = false;
        connectionCount++;
        lastCloseReason = reason.length > 0 ? reason : "TransportError";
        querySetVersion = 0;
        remoteVersion = StateVersion(0, 0, 0, initialTimestamp);
        fragmentedText = false;
        fragmentedPayload = [];
        foreach (state; subscriptions.byValue())
        {
            if (state.active && !state.removePending)
            {
                state.rehydrating = state.hasLastValue;
                state.addPending = true;
                state.addDone = false;
            }
        }
    }

    private int waitSocket(short events, int timeoutMs)
    {
        curl_socket_t descriptor = cast(curl_socket_t) CURL_SOCKET_BAD;
        synchronized (mutex)
        {
            if (socket is null || curl_easy_getinfo(socket, curlInfoActiveSocket,
                    &descriptor) != CurlError.ok || descriptor == CURL_SOCKET_BAD)
                return -1;
        }
        pollfd entry;
        entry.fd = descriptor;
        entry.events = events;
        return poll(&entry, 1, timeoutMs);
    }
}

private bool jsonString(JSONValue value, string name)
{
    return value.type == JSONType.object && name in value.object
        && value.object[name].type == JSONType.string;
}

private bool jsonUint(JSONValue value, string name)
{
    return value.type == JSONType.object && name in value.object
        && value.object[name].type == JSONType.integer
        && value.object[name].integer >= 0 && value.object[name].integer <= uint.max;
}

private bool decodeTimestamp(string encoded, ref ulong value)
{
    if (encoded.length != 12)
        return false;
    ubyte[] decoded;
    try
    {
        decoded = Base64.decode(encoded);
    }
    catch (Exception)
    {
        return false;
    }
    if (decoded.length != 8 || Base64.encode(decoded).idup != encoded)
        return false;
    value = 0;
    foreach (index, octet; decoded)
        value |= cast(ulong) octet << (8 * index);
    return true;
}

private long monotonicMilliseconds()
{
    import core.time : MonoTime;

    return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1_000);
}

private int nextBackoff(int current)
{
    return current < 7_500 ? current * 2 : 15_000;
}

private string curlError(CURLcode code)
{
    auto text = curl_easy_strerror(code);
    return text is null ? "libcurl error " ~ code.to!string : text.fromStringz.idup;
}

private extern (C) int liveDialProgress(void* context, double, double, double, double)
{
    auto manager = cast(LiveManager) context;
    return manager is null || manager.shouldCancelDial() ? 1 : 0;
}

version (ConvexAdapter)
{
    /** Test-adapter-only fault injection. This is deliberately absent from a
     * normal educational client build. */
    void adapterDebugDisconnect(ConvexClient client, int timeoutMs = 2_000)
    {
        LiveManager manager;
        synchronized (client.stateMutex)
        {
            client.ensureOpenLocked();
            manager = client.live;
        }
        if (manager is null)
            throw new ConvexError("TransportError", "Live WebSocket is not connected");
        manager.debugDisconnect(timeoutMs);
    }
}

unittest
{
    ulong decoded;
    assert(decodeTimestamp("/wAAAAAAAAA=", decoded) && decoded == 255);
    assert(decodeTimestamp("AAEAAAAAAAA=", decoded) && decoded == 256);
    assert(!decodeTimestamp("AAEAAAAAAA==", decoded));
    assert(!decodeTimestamp("not-base64!!", decoded));
}

unittest
{
    auto manager = new LiveManager("http://127.0.0.1:9", clientVersion);
    auto first = new SubscriptionState();
    first.active = false;
    first.queryId = 0;
    auto second = new SubscriptionState();
    second.active = false;
    second.queryId = 1;
    synchronized (manager.mutex)
    {
        manager.subscriptions[0] = first;
        manager.subscriptions[1] = second;
        foreach (number; 0 .. 20)
        {
            auto update = new LiveUpdate();
            update.hasValue = true;
            update.value = JSONValue(cast(long) number);
            manager.enqueueLocked(first, update);
        }
        assert(first.queue.length == liveQueueCapacity);
        assert(first.queue[0].value.integer == 4);
        auto large = new char[1024 * 1024];
        large[] = 'x';
        foreach (number; 0 .. 10)
        {
            auto update = new LiveUpdate();
            update.hasValue = true;
            update.value = JSONValue(large.idup ~ number.to!string);
            manager.enqueueLocked(number % 2 == 0 ? first : second, update);
        }
        assert(manager.queuedBytes <= liveQueueBudgetBytes);
    }
    version (ConvexAdapter)
    {
        size_t before;
        synchronized (manager.mutex)
            before = manager.queuedBytes;
        auto subscription = new ConvexSubscription(manager, first);
        auto retained = subscription.nextRetained(0);
        assert(retained !is null);
        synchronized (manager.mutex)
            assert(manager.queuedBytes == before);
        subscription.releaseRetained(retained);
        synchronized (manager.mutex)
            assert(manager.queuedBytes == before - retained.retainedBytes);
    }
    manager.close(1_000);
}
