using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Convex;

/// <summary>Pinned convex-rs 0.10.4 unversioned /api/sync profile, with bounded newest-16 delivery.</summary>
public sealed class LiveClient(string deployment) : IDisposable
{
    private readonly Uri _endpoint = ToWebSocket(deployment);
    private readonly Dictionary<int, Subscription> _subscriptions = [];
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ClientWebSocket? _socket;
    private int _nextId, _querySet, _connections;
    private bool _closed, _reconnecting;
    private string _lastClose = "InitialConnect";
    private JsonObject _version = ZeroVersion();
    private CancellationTokenSource _lifetime = new();
    private static Uri ToWebSocket(string value) { var u = new Uri(value.TrimEnd('/')); return new UriBuilder(u) { Scheme = u.Scheme == "https" ? "wss" : "ws", Path = u.AbsolutePath.TrimEnd('/') + "/api/sync" }.Uri; }
    public async Task<Subscription> Subscribe(string path, JsonObject args)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("Convex function path is required");
        await _gate.WaitAsync(); try {
            ThrowIfClosed(); var s = new Subscription(this, _nextId++, path, (JsonObject)args.DeepClone()); _subscriptions.Add(s.QueryId, s);
            try { if (_socket is null) await Connect(); else await Modify([Add(s)]); return s; }
            catch { _subscriptions.Remove(s.QueryId); throw; }
        } finally { _gate.Release(); }
    }
    private async Task Connect()
    {
        ThrowIfClosed(); var socket = new ClientWebSocket(); socket.Options.SetRequestHeader("Convex-Client", "csharp-0.1.0");
        await socket.ConnectAsync(_endpoint, _lifetime.Token); _socket = socket; _querySet = 0; _version = ZeroVersion();
        _ = Receive(socket);
        await Send(new JsonObject { ["type"]="Connect", ["sessionId"]=Guid.NewGuid().ToString(), ["connectionCount"]=_connections, ["lastCloseReason"]=_lastClose, ["clientTs"]=0 });
        if (_subscriptions.Count > 0) await Modify(_subscriptions.Values.Select(Add).ToArray());
        _reconnecting = false;
    }
    private JsonObject Add(Subscription s) => new() { ["type"]="Add", ["queryId"]=s.QueryId, ["udfPath"]=s.Path, ["args"]=new JsonArray((JsonNode)s.Args.DeepClone()) };
    private async Task Modify(IEnumerable<JsonObject> modifications) { await Send(new JsonObject { ["type"]="ModifyQuerySet", ["baseVersion"]=_querySet, ["newVersion"]=_querySet+1, ["modifications"]=new JsonArray(modifications.Select(x => (JsonNode)x).ToArray()) }); _querySet++; }
    private async Task Send(JsonObject message) { var s = _socket ?? throw new InvalidOperationException("Live WebSocket is not connected"); await s.SendAsync(Encoding.UTF8.GetBytes(message.ToJsonString()), WebSocketMessageType.Text, true, _lifetime.Token); }
    private async Task Receive(ClientWebSocket socket)
    {
        var buffer = new byte[65536]; var text = new StringBuilder();
        try { while (!_closed && socket.State == WebSocketState.Open) { var r = await socket.ReceiveAsync(buffer, _lifetime.Token); if (r.MessageType == WebSocketMessageType.Close) break; text.Append(Encoding.UTF8.GetString(buffer,0,r.Count)); if (r.EndOfMessage) { Handle(JsonNode.Parse(text.ToString())?.AsObject() ?? throw new Exception("empty Live frame")); text.Clear(); } } }
        catch (OperationCanceledException) when (_closed) { return; } catch { }
        await Disconnect("TransportError", true);
    }
    private void Handle(JsonObject message)
    {
        var type = message["type"]?.GetValue<string>(); if (type is "Ping" or "MutationResponse" or "ActionResponse") return;
        if (type is not "Transition") throw new ConvexClient.ProtocolException("unsupported Live message: " + type);
        if (!JsonNode.DeepEquals(message["startVersion"], _version)) throw new ConvexClient.ProtocolException("Live transition version mismatch");
        foreach (var n in message["modifications"]?.AsArray() ?? []) { var m=n!.AsObject(); if (!_subscriptions.TryGetValue(m["queryId"]!.GetValue<int>(), out var s)) continue; var logs=m["logLines"]?.AsArray().Select(x=>x!.GetValue<string>()).ToArray() ?? []; if (m["type"]?.GetValue<string>() == "QueryUpdated") s.Offer(new Update(m["value"]!, null, logs)); else if (m["type"]?.GetValue<string>() == "QueryFailed") s.Offer(new Update(null, new ConvexClient.FunctionException("query",m["errorMessage"]?.GetValue<string>() ?? "query failed",m["errorData"],logs),logs)); }
        _version = (JsonObject)message["endVersion"]!.DeepClone();
    }
    private async Task Disconnect(string reason, bool reconnect)
    {
        await _gate.WaitAsync(); try { if (_socket is not null) { _socket.Abort(); _socket.Dispose(); _socket=null; _connections++; } _lastClose=reason; _querySet=0; _version=ZeroVersion(); if (reconnect && _subscriptions.Count>0 && !_closed && !_reconnecting) { _reconnecting=true; _=Reconnect(); } } finally { _gate.Release(); }
    }
    private async Task Reconnect() { var delay=100; while (!_closed) { try { await Task.Delay(delay,_lifetime.Token); await _gate.WaitAsync(_lifetime.Token); try { if (_socket is null) await Connect(); return; } finally {_gate.Release();} } catch (OperationCanceledException) { return; } catch { delay=Math.Min(delay*2,15000); } } }
    public async Task DebugDisconnect() { await Disconnect("DebugDisconnect", true); }
    internal async Task Unsubscribe(Subscription s) { await _gate.WaitAsync(); try { if (_subscriptions.Remove(s.QueryId)) { s.Finish(); if (_socket is not null) await Modify([new JsonObject { ["type"]="Remove", ["queryId"]=s.QueryId }]); } } finally { _gate.Release(); } }
    private static JsonObject ZeroVersion() => new() { ["querySet"]=0,["identity"]=0,["ts"]="AAAAAAAAAAA=" };
    private void ThrowIfClosed() { if (_closed) throw new ObjectDisposedException(nameof(LiveClient)); }
    public void Dispose() { if (_closed) return; _closed=true; _lifetime.Cancel(); _socket?.Abort(); foreach(var s in _subscriptions.Values)s.Finish(); _subscriptions.Clear(); _lifetime.Dispose(); _gate.Dispose(); }
    public record Update(JsonNode? Value, Exception? Error, IReadOnlyList<string> Logs);
    public sealed class Subscription(LiveClient owner, int queryId, string path, JsonObject args) : IDisposable
    { internal int QueryId {get;}=queryId; internal string Path {get;}=path; internal JsonObject Args {get;}=args; private readonly BlockingCollection<Update> _updates=new(16); private bool _closed;
      internal void Offer(Update u) { if (_closed)return; if(!_updates.TryAdd(u)){_updates.TryTake(out _);_updates.TryAdd(u);} }
      internal void Finish(){_closed=true;_updates.CompleteAdding();}
      public Update NextUpdate(TimeSpan timeout){if(_updates.TryTake(out var u,(int)timeout.TotalMilliseconds))return u; throw new TimeoutException("timed out waiting for Live update");}
      public JsonNode Next(TimeSpan timeout){var u=NextUpdate(timeout);if(u.Error is not null)throw u.Error;return u.Value!;}
      public void Dispose(){if(!_closed) owner.Unsubscribe(this).GetAwaiter().GetResult();}
    }
}
