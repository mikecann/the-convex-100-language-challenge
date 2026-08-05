using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;
using Convex;

namespace ConvexAdapter;

/// <summary>Test-only NDJSON adapter protocol v1. It deliberately calls the native C# client.</summary>
public static class Program
{
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
    public static async Task Main()
    {
        var listen = Environment.GetEnvironmentVariable("ADAPTER_LISTEN");
        if (string.IsNullOrWhiteSpace(listen)) await Run(Console.In, Console.Out, Environment.GetEnvironmentVariable("CONVEX_URL"));
        else { var parts=listen.Split(':'); var server=new TcpListener(IPAddress.Parse(parts[0]),int.Parse(parts[1])); server.Start(); using var tcp=await server.AcceptTcpClientAsync(); using var stream=tcp.GetStream(); using var input=new StreamReader(stream); using var output=new StreamWriter(stream){AutoFlush=true}; await Run(input,output,Environment.GetEnvironmentVariable("CONVEX_URL")); }
    }
    private static async Task Run(TextReader input, TextWriter output, string? url)
    {
        var writer = new LockedWriter(output); var subs = new Dictionary<string,LiveClient.Subscription>(); ConvexClient? client=null; LiveClient? live=null;
        try { for (string? line; (line=await input.ReadLineAsync()) is not null;) { JsonObject command; try { command=JsonNode.Parse(line)?.AsObject() ?? throw new Exception("command is not an object"); } catch(Exception e) { await writer.Write(Failure(null,null,e)); continue; }
            var id=command["id"]?.GetValue<string>(); var op=command["op"]?.GetValue<string>();
            try { if(op=="hello") { if(command["protocolVersion"]?.GetValue<int>()!=1)throw new ArgumentException("unsupported adapter protocol version"); await writer.Write(Event("ready",id,new(){["protocolVersion"]=1,["language"]="csharp",["implementation"]="native-csharp-net8",["runtime"]=Environment.Version.ToString()})); continue; }
              if(op=="close") { foreach(var s in subs.Values)s.Dispose(); live?.Dispose(); client?.Dispose(); await writer.Write(Event("closed",id)); return; }
              if(string.IsNullOrWhiteSpace(url))throw new InvalidOperationException("CONVEX_URL is required"); client ??= new ConvexClient(url);
              if(op=="setAuth") { client.SetAuth(command["token"]?.GetValue<string>()); await writer.Write(Event("ack",id)); }
              else if(op is "query" or "mutation" or "action") { var args=command["args"]?.AsObject() ?? []; var r=op=="query"?await client.Query(command["path"]!.GetValue<string>(),args):op=="mutation"?await client.Mutation(command["path"]!.GetValue<string>(),args):await client.Action(command["path"]!.GetValue<string>(),args); await writer.Write(Event("result",id,new(){["value"]=r.Value,["logs"]=r.Logs.Count==0?null:JsonSerializer.SerializeToNode(r.Logs)})); }
              else if(op=="subscribe") { var sid=command["subscriptionId"]?.GetValue<string>(); if(string.IsNullOrWhiteSpace(sid))throw new ArgumentException("subscriptionId is required"); if(subs.Remove(sid!,out var old))old.Dispose(); live ??=new LiveClient(url); var s=await live.Subscribe(command["path"]!.GetValue<string>(),command["args"]?.AsObject()??[]); subs.Add(sid!,s); await writer.Write(Event("ack",id)); _=Relay(sid!,s,subs,writer); }
              else if(op=="unsubscribe") { var sid=command["subscriptionId"]?.GetValue<string>()??"";if(subs.Remove(sid,out var s))s.Dispose();await writer.Write(Event("ack",id)); }
              else if(op=="debugDisconnect") { if(live is null)throw new InvalidOperationException("Live WebSocket is not connected");await live.DebugDisconnect();await writer.Write(Event("ack",id)); }
              else throw new ArgumentException("unknown operation: "+op);
            } catch(Exception e) { await writer.Write(Failure(id,null,e)); }
        }} finally { foreach(var s in subs.Values)s.Dispose(); live?.Dispose();client?.Dispose(); }
    }
    private static async Task Relay(string sid,LiveClient.Subscription s,Dictionary<string,LiveClient.Subscription> subs,LockedWriter outp) { try { while(subs.TryGetValue(sid,out var current)&&ReferenceEquals(current,s)) { var u=s.NextUpdate(TimeSpan.FromDays(1)); if(u.Error is not null)await outp.Write(Failure(null,sid,u.Error)); else await outp.Write(Event("subscription",null,new(){["subscriptionId"]=sid,["value"]=u.Value,["logs"]=u.Logs.Count==0?null:JsonSerializer.SerializeToNode(u.Logs)})); } }catch(Exception e){if(subs.ContainsKey(sid))await outp.Write(Failure(null,sid,e));} }
    private static JsonObject Event(string type,string? id,JsonObject? extra=null){var o=extra??[];o["type"]=type;if(id is not null)o["id"]=id;return o;}
    private static JsonObject Failure(string? id,string? sid,Exception e){var name=e switch {ConvexClient.FunctionException=>"FunctionError",ConvexClient.TransportException=>"TransportError",ConvexClient.ProtocolException=>"ProtocolError",_=>e.GetType().Name};var o=Event(sid is null?"error":"subscription",id,new(){["subscriptionId"]=sid,["error"]=new JsonObject{{"name",name},{"message",e.Message}}});if(e is ConvexClient.FunctionException f){o["error"]!.AsObject()["data"]=f.ErrorData;if(f.Logs.Count>0)o["logs"]=JsonSerializer.SerializeToNode(f.Logs);}return o;}
    private sealed class LockedWriter(TextWriter target){private readonly SemaphoreSlim gate=new(1,1);public async Task Write(JsonObject value){await gate.WaitAsync();try{await target.WriteLineAsync(value.ToJsonString(Json));}finally{gate.Release();}}}
}
