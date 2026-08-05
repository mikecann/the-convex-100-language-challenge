using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Convex;

/// <summary>Pinned convex-rs 0.10.4 unversioned /api/sync profile, with bounded newest-16 delivery.</summary>
public sealed class LiveClient(string deployment) : IDisposable
{
    internal static Action? DebugPumpStopped;
    internal static Action? DebugSocketDetached;
    internal static Action? ReconnectAttempting;
    internal static Func<Task>? TransitionBeforeCommit;
    private readonly Uri _endpoint = ToWebSocket(deployment);
    private readonly ConcurrentDictionary<int, Subscription> _subscriptions = [];
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ClientWebSocket? _socket;
    private Task? _receiveTask;
    private int _nextId,
        _querySet,
        _connections;
    private bool _closed,
        _reconnecting;
    private volatile bool _intentionalRecovery;
    private string _lastClose = "InitialConnect";
    private string? _maxObservedTimestamp;
    private JsonObject _version = ZeroVersion();
    private readonly CancellationTokenSource _lifetime = new();
    private static readonly System.Text.UTF8Encoding StrictUtf8 = new(false, true);

    private static Uri ToWebSocket(string value)
    {
        var u = new Uri(value.TrimEnd('/'));
        return new UriBuilder(u)
        {
            Scheme = u.Scheme == "https" ? "wss" : "ws",
            Path = u.AbsolutePath.TrimEnd('/') + "/api/sync",
        }.Uri;
    }

    public async Task<Subscription> Subscribe(string path, JsonObject args)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("Convex function path is required");
        await _gate.WaitAsync();
        try
        {
            ThrowIfClosed();
            var s = new Subscription(this, _nextId++, path, (JsonObject)args.DeepClone());
            if (!_subscriptions.TryAdd(s.QueryId, s))
                throw new InvalidOperationException("duplicate Live query id");
            try
            {
                if (_socket is null)
                    await Connect();
                else
                    await Modify([Add(s)]);
                return s;
            }
            catch
            {
                _subscriptions.TryRemove(s.QueryId, out _);
                throw;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task Connect()
    {
        ThrowIfClosed();
        var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Convex-Client", "csharp-0.1.0");
        await socket.ConnectAsync(_endpoint, _lifetime.Token);
        _socket = socket;
        _querySet = 0;
        _version = ZeroVersion();
        _receiveTask = Receive(socket);
        var connect = new JsonObject
        {
            ["type"] = "Connect",
            ["sessionId"] = Guid.NewGuid().ToString(),
            ["connectionCount"] = _connections,
            ["lastCloseReason"] = _lastClose,
            ["clientTs"] = 0,
        };
        if (_maxObservedTimestamp is not null)
            connect["maxObservedTimestamp"] = _maxObservedTimestamp;
        await Send(connect);
        if (_subscriptions.Count > 0)
            await Modify(_subscriptions.Values.Select(Add).ToArray());
    }

    private JsonObject Add(Subscription s) =>
        new()
        {
            ["type"] = "Add",
            ["queryId"] = s.QueryId,
            ["udfPath"] = s.Path,
            ["args"] = new JsonArray((JsonNode)s.Args.DeepClone()),
        };

    private async Task Modify(IEnumerable<JsonObject> modifications)
    {
        await Send(
            new JsonObject
            {
                ["type"] = "ModifyQuerySet",
                ["baseVersion"] = _querySet,
                ["newVersion"] = _querySet + 1,
                ["modifications"] = new JsonArray(modifications.Select(x => (JsonNode)x).ToArray()),
            }
        );
        _querySet++;
    }

    private async Task Send(JsonObject message)
    {
        var socket =
            _socket ?? throw new InvalidOperationException("Live WebSocket is not connected");
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        bounded.CancelAfter(TimeSpan.FromSeconds(3));
        await socket.SendAsync(
            System.Text.Encoding.UTF8.GetBytes(message.ToJsonString()),
            WebSocketMessageType.Text,
            true,
            bounded.Token
        );
    }

    private async Task Receive(ClientWebSocket socket)
    {
        var buffer = new byte[4096];
        using var frame = new MemoryStream();
        Exception? failure = null;
        try
        {
            while (!_closed && socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, _lifetime.Token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    failure = new ConvexClient.TransportException(
                        "live",
                        new WebSocketException("Live WebSocket closed unexpectedly")
                    );
                    break;
                }
                if (result.MessageType != WebSocketMessageType.Text)
                    throw new ConvexClient.ProtocolException("Live server sent a non-text frame");
                frame.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage)
                    continue;
                var json = StrictUtf8.GetString(frame.GetBuffer(), 0, checked((int)frame.Length));
                frame.SetLength(0);
                await Handle(
                    socket,
                    JsonNode.Parse(json)?.AsObject()
                        ?? throw new ConvexClient.ProtocolException("empty Live frame")
                );
            }
        }
        catch (OperationCanceledException) when (_closed)
        {
            return;
        }
        catch (ConvexClient.ProtocolException error)
        {
            failure = error;
        }
        catch (Exception error)
        {
            failure = new ConvexClient.TransportException("live", error);
        }

        await Disconnect(
            socket,
            failure is ConvexClient.ProtocolException ? "ProtocolError" : "TransportError",
            true,
            failure
        );
    }

    private async Task Handle(ClientWebSocket socket, JsonObject message)
    {
        var type = message["type"]?.GetValue<string>();
        if (type is "Ping" or "MutationResponse" or "ActionResponse")
            return;
        if (type is not "Transition")
            throw new ConvexClient.ProtocolException("unsupported Live message: " + type);
        var startVersion =
            message["startVersion"]?.AsObject()
            ?? throw new ConvexClient.ProtocolException("Live transition omitted startVersion");
        var endVersion =
            message["endVersion"]?.AsObject()
            ?? throw new ConvexClient.ProtocolException("Live transition omitted endVersion");
        var updates = new List<(int QueryId, Update Update)>();
        foreach (var n in message["modifications"]?.AsArray() ?? [])
        {
            var m =
                n?.AsObject()
                ?? throw new ConvexClient.ProtocolException(
                    "Live transition contained an invalid modification"
                );
            var queryId =
                m["queryId"]?.GetValue<int>()
                ?? throw new ConvexClient.ProtocolException("Live modification omitted queryId");
            var modificationType = m["type"]?.GetValue<string>();
            if (modificationType == "QueryRemoved")
                continue;
            var logs =
                m["logLines"]?.AsArray().Select(x => x?.GetValue<string>() ?? "").ToArray() ?? [];
            if (modificationType == "QueryUpdated")
            {
                if (!m.ContainsKey("value"))
                    throw new ConvexClient.ProtocolException("QueryUpdated omitted value");
                updates.Add((queryId, new Update(m["value"]?.DeepClone(), null, logs)));
            }
            else if (modificationType == "QueryFailed")
            {
                updates.Add(
                    (
                        queryId,
                        new Update(
                            null,
                            new ConvexClient.FunctionException(
                                "query",
                                m["errorMessage"]?.GetValue<string>() ?? "query failed",
                                m["errorData"]?.DeepClone(),
                                logs
                            ),
                            logs
                        )
                    )
                );
            }
            else
                throw new ConvexClient.ProtocolException(
                    "unsupported Live transition modification: " + modificationType
                );
        }

        // Validation and commit are deliberately separate. Tests pause between
        // them to prove a detached receive pump cannot publish or advance state.
        await _gate.WaitAsync();
        try
        {
            if (!ReferenceEquals(_socket, socket))
                return;
            if (!JsonNode.DeepEquals(startVersion, _version))
                throw new ConvexClient.ProtocolException("Live transition version mismatch");
        }
        finally
        {
            _gate.Release();
        }
        if (TransitionBeforeCommit is not null)
            await TransitionBeforeCommit();
        await _gate.WaitAsync();
        try
        {
            if (!ReferenceEquals(_socket, socket))
                return;
            if (!JsonNode.DeepEquals(startVersion, _version))
                throw new ConvexClient.ProtocolException("Live transition version mismatch");
            var restoredActiveQuery = false;
            foreach (var update in updates)
                if (_subscriptions.TryGetValue(update.QueryId, out var subscription))
                {
                    subscription.Offer(update.Update);
                    restoredActiveQuery = true;
                }
            _version = (JsonObject)endVersion.DeepClone();
            _maxObservedTimestamp = _version["ts"]?.GetValue<string>();
            if (restoredActiveQuery)
                _intentionalRecovery = false;
        }
        finally
        {
            _gate.Release();
        }
    }

    private void DeliverFailure(Exception failure)
    {
        Subscription[] affected;
        affected = _subscriptions.Values.ToArray();
        foreach (var subscription in affected)
            subscription.Offer(new Update(null, failure, []));
    }

    private async Task Disconnect(
        ClientWebSocket? expected,
        string reason,
        bool reconnect,
        Exception? failure = null
    )
    {
        await _gate.WaitAsync();
        try
        {
            if (expected is not null && !ReferenceEquals(_socket, expected))
                return;
            if (failure is not null && !_intentionalRecovery)
                DeliverFailure(failure);
            if (_socket is not null)
            {
                _socket.Abort();
                _socket.Dispose();
                _socket = null;
                _connections++;
            }
            _lastClose = reason;
            _querySet = 0;
            _version = ZeroVersion();
            if (reconnect && _subscriptions.Count > 0 && !_closed && !_reconnecting)
            {
                _reconnecting = true;
                _ = Reconnect();
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task Reconnect()
    {
        var delay = 100;
        while (!_closed)
        {
            try
            {
                await Task.Delay(delay, _lifetime.Token);
                ReconnectAttempting?.Invoke();
                await _gate.WaitAsync(_lifetime.Token);
                try
                {
                    if (_socket is null)
                        await Connect();
                    _reconnecting = false;
                    return;
                }
                finally
                {
                    _gate.Release();
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                delay = Math.Min(delay * 2, 15000);
            }
        }
    }

    public async Task DebugDisconnect()
    {
        Task? stoppedPump;
        await _gate.WaitAsync();
        try
        {
            ThrowIfClosed();
            var previous =
                _socket ?? throw new InvalidOperationException("Live WebSocket is not connected");
            _socket = null;
            stoppedPump = _receiveTask;
            _receiveTask = null;
            previous.Abort();
            previous.Dispose();
            _connections++;
            _lastClose = "DebugDisconnect";
            _querySet = 0;
            _version = ZeroVersion();
            _intentionalRecovery = true;
        }
        finally
        {
            _gate.Release();
        }
        DebugSocketDetached?.Invoke();

        if (stoppedPump is not null)
            await stoppedPump.WaitAsync(TimeSpan.FromSeconds(3));
        DebugPumpStopped?.Invoke();

        // Start the ordinary backoff only after the old receive pump has stopped.
        // The adapter can now acknowledge debugDisconnect before the 100 ms delay expires.
        await _gate.WaitAsync();
        try
        {
            if (!_closed && _subscriptions.Count > 0 && _socket is null && !_reconnecting)
            {
                _reconnecting = true;
                _ = Reconnect();
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task Unsubscribe(Subscription s)
    {
        await _gate.WaitAsync();
        try
        {
            if (_subscriptions.TryRemove(s.QueryId, out _))
            {
                s.Finish();
                if (_socket is not null)
                    await Modify([new JsonObject { ["type"] = "Remove", ["queryId"] = s.QueryId }]);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private static JsonObject ZeroVersion() =>
        new()
        {
            ["querySet"] = 0,
            ["identity"] = 0,
            ["ts"] = "AAAAAAAAAAA=",
        };

    private void ThrowIfClosed()
    {
        if (_closed)
            throw new ObjectDisposedException(nameof(LiveClient));
    }

    public void Dispose()
    {
        if (_closed)
            return;
        _closed = true;
        _intentionalRecovery = false;
        _lifetime.Cancel();
        var socket = _socket;
        _socket = null;
        _receiveTask = null;
        socket?.Abort();
        socket?.Dispose();
        foreach (var s in _subscriptions.Values)
            s.Finish();
        _subscriptions.Clear();
    }

    public record Update(JsonNode? Value, Exception? Error, IReadOnlyList<string> Logs);

    public sealed class Subscription(LiveClient owner, int queryId, string path, JsonObject args)
        : IDisposable
    {
        internal int QueryId { get; } = queryId;
        internal string Path { get; } = path;
        internal JsonObject Args { get; } = args;
        private readonly BlockingCollection<Update> _updates = new(16);
        private readonly object _deliveryLock = new();
        private bool _closed;
        internal Action? OfferInsideLock;
        internal Action? FinishBeforeLock;

        internal void Offer(Update u)
        {
            lock (_deliveryLock)
            {
                if (_closed)
                    return;
                OfferInsideLock?.Invoke();
                if (!_updates.TryAdd(u))
                {
                    _updates.TryTake(out _);
                    _updates.TryAdd(u);
                }
            }
        }

        internal void Finish()
        {
            FinishBeforeLock?.Invoke();
            lock (_deliveryLock)
            {
                if (_closed)
                    return;
                _closed = true;
                _updates.CompleteAdding();
            }
        }

        public Update NextUpdate(TimeSpan timeout)
        {
            if (_updates.TryTake(out var u, (int)timeout.TotalMilliseconds))
                return u;
            throw new TimeoutException("timed out waiting for Live update");
        }

        public JsonNode Next(TimeSpan timeout)
        {
            var u = NextUpdate(timeout);
            if (u.Error is not null)
                throw u.Error;
            return u.Value!;
        }

        public void Dispose()
        {
            if (!_closed)
                owner.Unsubscribe(this).GetAwaiter().GetResult();
        }
    }
}
