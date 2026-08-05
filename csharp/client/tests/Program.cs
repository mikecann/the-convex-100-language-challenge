using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Convex;
using Adapter = ConvexAdapter.Program;

static class Tests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    public static async Task Main()
    {
        TestAdapterSerialization();
        await TestHttp();
        await TestAdapterHttpOperations();
        await TestAdapterTcp();
        await TestAdapterLiveControllerLifecycle();
        await TestAdapterSuppressesStaleRelayAfterUnsubscribe();
        await TestAdapterSuppressesStaleRelayAfterReplacement();
        TestBoundedDelivery();
        await TestOfferFinishOrdering();
        await TestLiveFlowAndUtf8Fragmentation();
        await TestReconnectAndResubscribe();
        await TestProtocolAndTransportRecovery();
        Console.WriteLine("C# client tests passed");
    }

    private static void TestAdapterSerialization()
    {
        var result = Adapter.Serialize(Adapter.ResultEvent("r", new ConvexClient.Result(new JsonObject { ["count"] = 1 }, [])));
        Equal("{\"type\":\"result\",\"id\":\"r\",\"value\":{\"count\":1}}", result, "result optional fields");
        var logged = Adapter.Serialize(Adapter.ResultEvent("r", new ConvexClient.Result(new JsonObject(), ["hello"])));
        Check(logged.Contains("\"logs\":[\"hello\"]"), "result logs were omitted");
        var subscription = Adapter.Serialize(Adapter.SubscriptionEvent("s", new LiveClient.Update(new JsonObject { ["text"] = "雪" }, null, [])));
        Equal("{\"type\":\"subscription\",\"subscriptionId\":\"s\",\"value\":{\"text\":\"\\u96EA\"}}", subscription, "subscription optional fields");
        Equal("{\"type\":\"subscription\",\"subscriptionId\":\"s\",\"value\":null}", Adapter.Serialize(Adapter.SubscriptionEvent("s", new LiveClient.Update(null, null, []))), "subscription JSON null shape");
        var plainError = Adapter.Serialize(Adapter.Failure("e", null, new InvalidOperationException("bad")));
        Check(!plainError.Contains("subscriptionId") && !plainError.Contains("logs") && !plainError.Contains("data"), "request error serialized absent fields");
        var functionError = Adapter.Serialize(Adapter.Failure(null, "s", new ConvexClient.FunctionException("query", "empty", new JsonObject { ["code"] = "EMPTY" }, ["checked"])));
        Check(!functionError.Contains("\"id\"") && functionError.Contains("\"subscriptionId\":\"s\"") && functionError.Contains("\"data\":{\"code\":\"EMPTY\"}") && functionError.Contains("\"logs\":[\"checked\"]"), "structured subscription error shape");
        Equal("{\"type\":\"closed\",\"id\":\"c\"}", Adapter.Serialize(Adapter.Event("closed", "c")), "closed event shape");
    }

    private static async Task TestHttp()
    {
        using var listener = Listen();
        var requests = new List<string>();
        var server = Task.Run(async () => {
            for(var operation=0;operation<4;operation++) {
                using var socket = await listener.AcceptTcpClientAsync();
                requests.Add(await ReadHttpRequest(socket.GetStream()));
                var response = operation < 3
                    ? "{\"status\":\"success\",\"value\":{\"text\":\"雪\",\"nested\":{\"ok\":true}},\"logLines\":[\"ran\"]}"
                    : "{\"status\":\"error\",\"errorMessage\":\"empty\",\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[\"checked\"]}";
                await WriteHttpResponse(socket.GetStream(), operation < 3 ? 200 : 560, response);
            }
        });
        using var client = new ConvexClient(Url(listener));
        client.SetAuth("secret-token");
        var reusableArgs = new JsonObject { ["text"] = "雪", ["nested"] = new JsonObject { ["value"] = 3 } };
        var success = await client.Query("demo:echo", reusableArgs);
        await client.Mutation("demo:echo", reusableArgs);
        await client.Action("demo:echo", reusableArgs);
        Equal("雪", success.Value!["text"]!.GetValue<string>(), "UTF-8 success value");
        Equal("ran", success.Logs[0], "success logs");
        Check(reusableArgs.Parent is null && reusableArgs["nested"]!.Parent == reusableArgs, "HTTP calls took ownership of reusable args");
        var request = requests[0];
        Check(request.Contains("Authorization: Bearer secret-token", StringComparison.OrdinalIgnoreCase), "auth header missing");
        var requestBody = JsonNode.Parse(request[(request.IndexOf("\r\n\r\n", StringComparison.Ordinal) + 4)..])!;
        Check(requestBody["path"]!.GetValue<string>() == "demo:echo" && requestBody["args"]!["text"]!.GetValue<string>() == "雪" && requestBody["args"]!["nested"]!["value"]!.GetValue<int>() == 3, "HTTP request formatting lost nested UTF-8 args");
        client.SetAuth(null);
        try { await client.Query("demo:error", new JsonObject()); throw new Exception("function error became success"); }
        catch (ConvexClient.FunctionException error) { Equal("ROOM_EMPTY", error.ErrorData!["code"]!.GetValue<string>(), "structured error data"); Equal("checked", error.Logs[0], "error logs"); }
        Check(!requests[3].Contains("Authorization:", StringComparison.OrdinalIgnoreCase), "clearing auth retained bearer header");
        await server.WaitAsync(Timeout);
    }

    private static async Task TestAdapterHttpOperations()
    {
        using var listener = Listen();
        var requests = new List<string>();
        var responses = new[] {
            "{\"status\":\"success\",\"value\":{\"text\":\"雪\",\"nested\":{\"ok\":true}},\"logLines\":[\"query log\"]}",
            "{\"status\":\"success\",\"value\":{\"applied\":true},\"logLines\":[]}",
            "{\"status\":\"success\",\"value\":{\"done\":true},\"logLines\":[\"action log\"]}",
            "{\"status\":\"error\",\"errorMessage\":\"empty\",\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[\"checked\"]}",
            "{\"status\":\"success\",\"value\":null,\"logLines\":[]}"
        };
        var server = Task.Run(async () => {
            for(var index=0;index<responses.Length;index++) {
                using var socket=await listener.AcceptTcpClientAsync();requests.Add(await ReadHttpRequest(socket.GetStream()));
                await WriteHttpResponse(socket.GetStream(),index==3?560:200,responses[index]);
            }
        });
        var input = string.Join('\n', new[] {
            "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:query\",\"args\":{\"text\":\"雪\",\"nested\":{\"value\":3}}}",
            "{\"id\":\"m\",\"op\":\"mutation\",\"path\":\"demo:mutation\",\"args\":{\"text\":\"雪\",\"nested\":{\"value\":3}}}",
            "{\"id\":\"a\",\"op\":\"action\",\"path\":\"demo:action\",\"args\":{\"text\":\"雪\",\"nested\":{\"value\":3}}}",
            "{\"id\":\"e\",\"op\":\"query\",\"path\":\"demo:error\",\"args\":{}}",
            "{\"id\":\"n\",\"op\":\"action\",\"path\":\"demo:null\",\"args\":{}}",
            "{\"id\":\"c\",\"op\":\"close\"}"
        }) + "\n";
        var output = new StringWriter();
        await Adapter.Run(new StringReader(input),output,Url(listener));
        await server.WaitAsync(Timeout);
        var events=output.ToString().Split('\n',StringSplitOptions.RemoveEmptyEntries).Select(line => JsonNode.Parse(line)).ToArray();
        Equal("雪",events[0]!["value"]!["text"]!.GetValue<string>(),"adapter query UTF-8 result");Equal("query log",events[0]!["logs"]![0]!.GetValue<string>(),"adapter query logs");
        Check(events[1]!["value"]!["applied"]!.GetValue<bool>()&&!events[1]!.AsObject().ContainsKey("logs"),"adapter mutation empty logs were not omitted");
        Check(events[2]!["value"]!["done"]!.GetValue<bool>()&&events[2]!["logs"]![0]!.GetValue<string>()=="action log","adapter action result/logs");
        Equal("ROOM_EMPTY",events[3]!["error"]!["data"]!["code"]!.GetValue<string>(),"adapter structured error");Equal("checked",events[3]!["logs"]![0]!.GetValue<string>(),"adapter error logs");
        Check(events[4]!.AsObject().ContainsKey("value")&&events[4]!["value"] is null&&!events[4]!.AsObject().ContainsKey("logs"),"adapter JSON null or empty logs shape");
        Equal("closed",events[5]!["type"]!.GetValue<string>(),"adapter HTTP close");
        foreach(var request in requests.Take(3)){var body=JsonNode.Parse(request[(request.IndexOf("\r\n\r\n",StringComparison.Ordinal)+4)..])!;Equal("雪",body["args"]!["text"]!.GetValue<string>(),"adapter nested UTF-8 args");Equal(3,body["args"]!["nested"]!["value"]!.GetValue<int>(),"adapter nested args");}
    }

    private static async Task TestAdapterTcp()
    {
        using var listener = Listen(); var port=((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        Environment.SetEnvironmentVariable("ADAPTER_LISTEN", "127.0.0.1:" + port);
        var adapter = Task.Run(Adapter.Main);
        TcpClient? controller=null;
        for(var i=0;i<50 && controller is null;i++) { try { controller=new TcpClient(); await controller.ConnectAsync(IPAddress.Loopback,port); } catch { controller?.Dispose();controller=null;await Task.Delay(20); } }
        Check(controller is not null, "adapter TCP listener did not start");
        var connected = controller ?? throw new Exception("adapter TCP listener did not start");
        using(connected) using(var stream=connected.GetStream()) using(var reader=new StreamReader(stream)) using(var writer=new StreamWriter(stream){AutoFlush=true}) {
            await writer.WriteLineAsync("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}");
            Check((await reader.ReadLineAsync())!.Contains("\"language\":\"csharp\""), "TCP hello failed");
            await writer.WriteLineAsync("{\"id\":\"close\",\"op\":\"close\"}");
            Equal("{\"type\":\"closed\",\"id\":\"close\"}", await reader.ReadLineAsync(), "TCP close event");
        }
        await adapter.WaitAsync(Timeout); Environment.SetEnvironmentVariable("ADAPTER_LISTEN", null);
    }

    private static async Task TestAdapterLiveControllerLifecycle()
    {
        using var syncListener=Listen();
        var syncServer=Task.Run(async()=>{
            using(var socket=await syncListener.AcceptTcpClientAsync()) {
                var stream=socket.GetStream();await Handshake(stream);await ReadClientText(stream);
                var firstAdd=JsonNode.Parse(await ReadClientText(stream))!;var firstId=firstAdd["modifications"]![0]!["queryId"]!.GetValue<int>();
                await WriteServerText(stream,Transition(Zero(),Version(1),new JsonObject{{"type","QueryUpdated"},{"queryId",firstId},{"value",new JsonObject{{"count",0}}},{"logLines",new JsonArray()}}).ToJsonString());
                var remove=JsonNode.Parse(await ReadClientText(stream))!;Equal("Remove",remove["modifications"]![0]!["type"]!.GetValue<string>(),"adapter unsubscribe did not send Remove");
                var secondAdd=JsonNode.Parse(await ReadClientText(stream))!;Equal("Add",secondAdd["modifications"]![0]!["type"]!.GetValue<string>(),"fresh adapter subscribe did not send Add");var secondId=secondAdd["modifications"]![0]!["queryId"]!.GetValue<int>();
                await WriteServerText(stream,Transition(Version(1),Version(2),new JsonObject{{"type","QueryUpdated"},{"queryId",secondId},{"value",new JsonObject{{"count",1}}},{"logLines",new JsonArray()}}).ToJsonString());
                await WaitForEof(stream);
            }
            for(var reconnect=1;reconnect<=5;reconnect++) {
                using var socket=await syncListener.AcceptTcpClientAsync();var stream=socket.GetStream();await Handshake(stream);
                var connect=JsonNode.Parse(await ReadClientText(stream))!;Equal(reconnect,connect["connectionCount"]!.GetValue<int>(),"adapter reconnect count");
                var add=JsonNode.Parse(await ReadClientText(stream))!;Equal("Add",add["modifications"]![0]!["type"]!.GetValue<string>(),"adapter reconnect did not restore query");var id=add["modifications"]![0]!["queryId"]!.GetValue<int>();
                await WriteServerText(stream,Transition(Zero(),Version(10+reconnect),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",reconnect+1}}},{"logLines",new JsonArray()}}).ToJsonString());
                await WaitForEof(stream);
            }
        });

        using var reserved=Listen();var adapterPort=((IPEndPoint)reserved.LocalEndpoint).Port;reserved.Stop();
        Environment.SetEnvironmentVariable("CONVEX_URL",Url(syncListener));
        Environment.SetEnvironmentVariable("ADAPTER_LISTEN","127.0.0.1:"+adapterPort);
        var adapter=Task.Run(Adapter.Main);
        TcpClient? controller=null;
        for(var attempt=0;attempt<50&&controller is null;attempt++){try{controller=new TcpClient();await controller.ConnectAsync(IPAddress.Loopback,adapterPort);}catch{controller?.Dispose();controller=null;await Task.Delay(20);}}
        var connected=controller??throw new Exception("controller-shaped adapter did not listen");
        using(connected) using(var stream=connected.GetStream()) using(var reader=new StreamReader(stream)) using(var writer=new StreamWriter(stream){AutoFlush=true}) {
            await writer.WriteLineAsync("{\"id\":\"s1\",\"op\":\"subscribe\",\"subscriptionId\":\"first\",\"path\":\"demo:state\",\"args\":{}}");
            Equal("ack",(await ReadEvent(reader))["type"]!.GetValue<string>(),"first subscribe ack");Equal(0,(await ReadEvent(reader))["value"]!["count"]!.GetValue<int>(),"first initial value");
            await writer.WriteLineAsync("{\"id\":\"u1\",\"op\":\"unsubscribe\",\"subscriptionId\":\"first\"}");
            var unsubscribe=await ReadEvent(reader);Equal("ack",unsubscribe["type"]!.GetValue<string>(),"unsubscribe ack while relay blocked");Equal("u1",unsubscribe["id"]!.GetValue<string>(),"unsubscribe ack id");
            await writer.WriteLineAsync("{\"id\":\"s2\",\"op\":\"subscribe\",\"subscriptionId\":\"second\",\"path\":\"demo:state\",\"args\":{}}");
            Equal("ack",(await ReadEvent(reader))["type"]!.GetValue<string>(),"fresh subscribe ack");Equal(1,(await ReadEvent(reader))["value"]!["count"]!.GetValue<int>(),"fresh initial value");
            for(var reconnect=1;reconnect<=5;reconnect++) {
                await writer.WriteLineAsync($"{{\"id\":\"d{reconnect}\",\"op\":\"debugDisconnect\"}}");
                var ack=await ReadEvent(reader);Equal("ack",ack["type"]!.GetValue<string>(),"debugDisconnect ack");Equal("d"+reconnect,ack["id"]!.GetValue<string>(),"debugDisconnect ack id");
                Equal(reconnect+1,(await ReadEvent(reader))["value"]!["count"]!.GetValue<int>(),"post-reconnect subscription value");
            }
            await writer.WriteLineAsync("{\"id\":\"client-close\",\"op\":\"close\"}");
            var closed=await ReadEvent(reader);Equal("closed",closed["type"]!.GetValue<string>(),"client close event");Equal("client-close",closed["id"]!.GetValue<string>(),"client close id");
        }
        await adapter.WaitAsync(Timeout);await syncServer.WaitAsync(Timeout);
        Environment.SetEnvironmentVariable("ADAPTER_LISTEN",null);Environment.SetEnvironmentVariable("CONVEX_URL",null);
    }

    private static void TestBoundedDelivery()
    {
        var subscription = new LiveClient.Subscription(null!, 7, "demo:state", new JsonObject());
        for(var value=0;value<20;value++) subscription.Offer(new LiveClient.Update(new JsonObject { ["count"] = value }, null, []));
        Equal(4, subscription.Next(Timeout)["count"]!.GetValue<int>(), "bounded queue did not drop oldest values");
        for(var value=5;value<20;value++) Equal(value,subscription.Next(Timeout)["count"]!.GetValue<int>(),"bounded queue order");
    }

    private static async Task TestOfferFinishOrdering()
    {
        var subscription=new LiveClient.Subscription(null!,8,"demo:state",new JsonObject());
        var offerEntered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finishEntered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOffer=new ManualResetEventSlim();
        subscription.OfferInsideLock=()=>{offerEntered.TrySetResult();releaseOffer.Wait(Timeout);};
        subscription.FinishBeforeLock=()=>finishEntered.TrySetResult();
        var offered=Task.Run(()=>subscription.Offer(new LiveClient.Update(new JsonObject{{"count",1}},null,[])));
        await offerEntered.Task.WaitAsync(Timeout);
        var finished=Task.Run(subscription.Finish);
        await finishEntered.Task.WaitAsync(Timeout);Check(!finished.IsCompleted,"Finish interleaved with Offer inside delivery lock");
        releaseOffer.Set();await offered.WaitAsync(Timeout);await finished.WaitAsync(Timeout);
        subscription.OfferInsideLock=null;subscription.FinishBeforeLock=null;
        subscription.Offer(new LiveClient.Update(new JsonObject{{"count",2}},null,[]));
        Equal(1,subscription.Next(Timeout)["count"]!.GetValue<int>(),"pre-finish update was lost");
        try{subscription.Next(TimeSpan.FromMilliseconds(20));throw new Exception("post-finish update was added");}catch(TimeoutException){}
    }

    private static Task TestAdapterSuppressesStaleRelayAfterUnsubscribe()=>TestStaleRelay(false);
    private static Task TestAdapterSuppressesStaleRelayAfterReplacement()=>TestStaleRelay(true);

    private static async Task TestStaleRelay(bool replace)
    {
        using var syncListener=Listen();
        var relayEntered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseRelay=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var oldPublishAttempted=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var barrierCalls=0;
        LiveClient.Subscription? oldSubscription=null;
        Adapter.RelayBeforePublish=(_,subscription,_)=>Interlocked.Increment(ref barrierCalls)==1?BlockRelay(subscription):Task.CompletedTask;
        Adapter.RelayAfterPublishAttempt=(_,subscription)=>{if(ReferenceEquals(subscription,oldSubscription))oldPublishAttempted.TrySetResult();};
        async Task BlockRelay(LiveClient.Subscription subscription){oldSubscription=subscription;relayEntered.TrySetResult();await releaseRelay.Task;}
        var syncServer=Task.Run(async()=>{
            using var socket=await syncListener.AcceptTcpClientAsync();var stream=socket.GetStream();await Handshake(stream);await ReadClientText(stream);
            var oldAdd=JsonNode.Parse(await ReadClientText(stream))!;var oldId=oldAdd["modifications"]![0]!["queryId"]!.GetValue<int>();
            var oldModification=replace
                ?new JsonObject{{"type","QueryFailed"},{"queryId",oldId},{"errorMessage","stale"},{"errorData",new JsonObject{{"code","STALE"}}},{"logLines",new JsonArray()}}
                :new JsonObject{{"type","QueryUpdated"},{"queryId",oldId},{"value",new JsonObject{{"count",99}}},{"logLines",new JsonArray()}};
            await WriteServerText(stream,Transition(Zero(),Version(1),oldModification).ToJsonString());
            var remove=JsonNode.Parse(await ReadClientText(stream))!;Equal("Remove",remove["modifications"]![0]!["type"]!.GetValue<string>(),"stale relay test Remove");
            if(replace){var replacement=JsonNode.Parse(await ReadClientText(stream))!;var newId=replacement["modifications"]![0]!["queryId"]!.GetValue<int>();await WriteServerText(stream,Transition(Version(1),Version(2),new JsonObject{{"type","QueryUpdated"},{"queryId",newId},{"value",new JsonObject{{"count",2}}},{"logLines",new JsonArray()}}).ToJsonString());}
            await WaitForEof(stream);
        });
        using var reserved=Listen();var adapterPort=((IPEndPoint)reserved.LocalEndpoint).Port;reserved.Stop();
        Environment.SetEnvironmentVariable("CONVEX_URL",Url(syncListener));Environment.SetEnvironmentVariable("ADAPTER_LISTEN","127.0.0.1:"+adapterPort);
        var adapter=Task.Run(Adapter.Main);TcpClient? controller=null;
        for(var attempt=0;attempt<50&&controller is null;attempt++){try{controller=new TcpClient();await controller.ConnectAsync(IPAddress.Loopback,adapterPort);}catch{controller?.Dispose();controller=null;await Task.Delay(20);}}
        var connected=controller??throw new Exception("stale relay adapter did not listen");
        try{
            using(connected)using(var stream=connected.GetStream())using(var reader=new StreamReader(stream))using(var writer=new StreamWriter(stream){AutoFlush=true}){
                await writer.WriteLineAsync("{\"id\":\"old\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}");Equal("ack",(await ReadEvent(reader))["type"]!.GetValue<string>(),"old subscribe ack");
                await relayEntered.Task.WaitAsync(Timeout);
                if(replace){await writer.WriteLineAsync("{\"id\":\"new\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}");Equal("new",(await ReadEvent(reader))["id"]!.GetValue<string>(),"replacement ack");Equal(2,(await ReadEvent(reader))["value"]!["count"]!.GetValue<int>(),"replacement update");}
                else{await writer.WriteLineAsync("{\"id\":\"unsubscribe\",\"op\":\"unsubscribe\",\"subscriptionId\":\"same\"}");Equal("unsubscribe",(await ReadEvent(reader))["id"]!.GetValue<string>(),"unsubscribe ack");}
                releaseRelay.TrySetResult();await oldPublishAttempted.Task.WaitAsync(Timeout);Check(!stream.DataAvailable,replace?"old replacement relay emitted stale error":"unsubscribed relay emitted stale value");
                await writer.WriteLineAsync("{\"id\":\"close\",\"op\":\"close\"}");Equal("closed",(await ReadEvent(reader))["type"]!.GetValue<string>(),"stale relay close");
            }
            await adapter.WaitAsync(Timeout);await syncServer.WaitAsync(Timeout);
        }finally{releaseRelay.TrySetResult();Adapter.RelayBeforePublish=null;Adapter.RelayAfterPublishAttempt=null;Environment.SetEnvironmentVariable("ADAPTER_LISTEN",null);Environment.SetEnvironmentVariable("CONVEX_URL",null);}
    }

    private static async Task TestLiveFlowAndUtf8Fragmentation()
    {
        using var listener=Listen();
        var server=Task.Run(async()=>{using var socket=await listener.AcceptTcpClientAsync();var stream=socket.GetStream();await Handshake(stream);await ReadClientText(stream);var add=JsonNode.Parse(await ReadClientText(stream))!.AsObject();var id=add["modifications"]![0]!["queryId"]!.GetValue<int>();
            var first=Transition(Zero(),Version(1),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",0},{"text","雪"}}},{"logLines",new JsonArray()}}).ToJsonString().Replace("\\u96EA","雪",StringComparison.OrdinalIgnoreCase);await WriteFragmentedUtf8(stream,first,"雪");
            await WriteServerText(stream,Transition(Version(1),Version(2),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",null},{"logLines",new JsonArray()}}).ToJsonString());
            await WriteServerText(stream,Transition(Version(2),Version(3),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",1}}},{"logLines",new JsonArray("updated")}}).ToJsonString());
            await WriteServerText(stream,Transition(Version(3),Version(4),new JsonObject{{"type","QueryFailed"},{"queryId",id},{"errorMessage","temporary"},{"errorData",new JsonObject{{"code","TEMP"}}},{"logLines",new JsonArray("failed")}}).ToJsonString());
            await WriteServerText(stream,Transition(Version(4),Version(5),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",2}}},{"logLines",new JsonArray()}}).ToJsonString());
            var remove=JsonNode.Parse(await ReadClientText(stream))!.AsObject();Equal("Remove",remove["modifications"]![0]!["type"]!.GetValue<string>(),"unsubscribe Remove");});
        using var live=new LiveClient(Url(listener)); var subscription=await live.Subscribe("demo:state",new JsonObject());
        Equal("雪",subscription.Next(Timeout)["text"]!.GetValue<string>(),"fragmented UTF-8 Live value");var nullUpdate=subscription.NextUpdate(Timeout);Check(nullUpdate.Error is null&&nullUpdate.Value is null,"Live JSON null was not delivered");Equal(1,subscription.Next(Timeout)["count"]!.GetValue<int>(),"Live update");
        var failed=subscription.NextUpdate(Timeout);Check(failed.Error is ConvexClient.FunctionException,"query error not delivered");Equal("TEMP",((ConvexClient.FunctionException)failed.Error!).ErrorData!["code"]!.GetValue<string>(),"query error data");
        Equal(2,subscription.Next(Timeout)["count"]!.GetValue<int>(),"query did not recover");subscription.Dispose();await server.WaitAsync(Timeout);
    }

    private static async Task TestReconnectAndResubscribe()
    {
        using var listener=Listen();
        var server=Task.Run(async()=>{for(var connection=0;connection<2;connection++){using var socket=await listener.AcceptTcpClientAsync();var stream=socket.GetStream();await Handshake(stream);var connect=JsonNode.Parse(await ReadClientText(stream))!.AsObject();Equal(connection,connect["connectionCount"]!.GetValue<int>(),"connection count");var add=JsonNode.Parse(await ReadClientText(stream))!.AsObject();Equal("Add",add["modifications"]![0]!["type"]!.GetValue<string>(),"reconnect did not resubscribe");var id=add["modifications"]![0]!["queryId"]!.GetValue<int>();await WriteServerText(stream,Transition(Zero(),Version(connection+1),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",connection}}},{"logLines",new JsonArray()}}).ToJsonString());if(connection==0)await WaitForEof(stream);else Equal("Remove",JsonNode.Parse(await ReadClientText(stream))!["modifications"]![0]!["type"]!.GetValue<string>(),"reconnect unsubscribe");}});
        using var live=new LiveClient(Url(listener));var subscription=await live.Subscribe("demo:state",new JsonObject());Equal(0,subscription.Next(Timeout)["count"]!.GetValue<int>(),"initial reconnect value");await live.DebugDisconnect();Equal(1,subscription.Next(Timeout)["count"]!.GetValue<int>(),"post-reconnect value");subscription.Dispose();await server.WaitAsync(Timeout);
    }

    private static async Task TestProtocolAndTransportRecovery()
    {
        using var listener=Listen();
        var server=Task.Run(async()=>{
            using(var socket=await listener.AcceptTcpClientAsync()){var stream=socket.GetStream();await Handshake(stream);await ReadClientText(stream);var add=JsonNode.Parse(await ReadClientText(stream))!.AsObject();var id=add["modifications"]![0]!["queryId"]!.GetValue<int>();await WriteServerText(stream,Transition(Zero(),Version(1),new JsonObject{{"type","UnknownModification"},{"queryId",id}}).ToJsonString());}
            using(var socket=await listener.AcceptTcpClientAsync()){var stream=socket.GetStream();await Handshake(stream);await ReadClientText(stream);var add=JsonNode.Parse(await ReadClientText(stream))!.AsObject();var id=add["modifications"]![0]!["queryId"]!.GetValue<int>();await WriteServerText(stream,Transition(Zero(),Version(2),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",7}}},{"logLines",new JsonArray()}}).ToJsonString());socket.Client.LingerState=new LingerOption(true,0);}
            using(var socket=await listener.AcceptTcpClientAsync()){var stream=socket.GetStream();await Handshake(stream);await ReadClientText(stream);var add=JsonNode.Parse(await ReadClientText(stream))!.AsObject();var id=add["modifications"]![0]!["queryId"]!.GetValue<int>();await WriteServerText(stream,Transition(Zero(),Version(3),new JsonObject{{"type","QueryUpdated"},{"queryId",id},{"value",new JsonObject{{"count",8}}},{"logLines",new JsonArray()}}).ToJsonString());Equal("Remove",JsonNode.Parse(await ReadClientText(stream))!["modifications"]![0]!["type"]!.GetValue<string>(),"recovery unsubscribe");}
        });
        using var live=new LiveClient(Url(listener));var subscription=await live.Subscribe("demo:state",new JsonObject());Check(subscription.NextUpdate(Timeout).Error is ConvexClient.ProtocolException,"unsupported modification vanished");Equal(7,subscription.Next(Timeout)["count"]!.GetValue<int>(),"protocol reconnect failed");Check(subscription.NextUpdate(Timeout).Error is ConvexClient.TransportException,"transport failure vanished");Equal(8,subscription.Next(Timeout)["count"]!.GetValue<int>(),"transport reconnect failed");subscription.Dispose();await server.WaitAsync(Timeout);
    }

    private static TcpListener Listen(){var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();return listener;}
    private static string Url(TcpListener listener)=>"http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port;
    private static JsonObject Zero()=>new(){{"querySet",0},{"identity",0},{"ts","AAAAAAAAAAA="}};
    private static JsonObject Version(int n)=>new(){{"querySet",1},{"identity",0},{"ts",Convert.ToBase64String(BitConverter.GetBytes((long)n))}};
    private static JsonObject Transition(JsonObject start,JsonObject end,JsonObject modification)=>new(){{"type","Transition"},{"startVersion",start},{"endVersion",end},{"modifications",new JsonArray(modification)}};
    private static async Task<string> ReadHttpRequest(NetworkStream stream){var bytes=new List<byte>();var matched=0;while(matched<4){var b=stream.ReadByte();if(b<0)throw new EndOfStreamException();bytes.Add((byte)b);matched=matched switch{0 when b=='\r'=>1,1 when b=='\n'=>2,2 when b=='\r'=>3,3 when b=='\n'=>4,_=>0};}var headers=Encoding.UTF8.GetString(bytes.ToArray());var length=0;foreach(var line in headers.Split("\r\n"))if(line.StartsWith("Content-Length:",StringComparison.OrdinalIgnoreCase))length=int.Parse(line.Split(':')[1].Trim());if(length==0&&headers.Contains("Transfer-Encoding: chunked",StringComparison.OrdinalIgnoreCase))length=Convert.ToInt32(ReadAsciiLine(stream),16);var body=new byte[length];await stream.ReadExactlyAsync(body);return headers+Encoding.UTF8.GetString(body);}
    private static async Task WriteHttpResponse(NetworkStream stream,int status,string body){var payload=Encoding.UTF8.GetBytes(body);var headers=Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n");await stream.WriteAsync(headers);await stream.WriteAsync(payload);}
    private static async Task Handshake(NetworkStream stream){var request=await ReadHeaders(stream);var key=request.Split("\r\n").First(x=>x.StartsWith("Sec-WebSocket-Key:",StringComparison.OrdinalIgnoreCase)).Split(':',2)[1].Trim();var accept=Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+accept+"\r\n\r\n"));}
    private static Task<string> ReadHeaders(NetworkStream stream){var bytes=new List<byte>();var matched=0;while(matched<4){var b=stream.ReadByte();if(b<0)throw new EndOfStreamException();bytes.Add((byte)b);matched=matched switch{0 when b=='\r'=>1,1 when b=='\n'=>2,2 when b=='\r'=>3,3 when b=='\n'=>4,_=>0};}return Task.FromResult(Encoding.ASCII.GetString(bytes.ToArray()));}
    private static async Task<string> ReadClientText(NetworkStream stream){var first=stream.ReadByte();var second=stream.ReadByte();if(first<0||second<0)throw new EndOfStreamException();long length=second&127;if(length==126)length=((long)(byte)stream.ReadByte()<<8)|(byte)stream.ReadByte();else if(length==127){length=0;for(var i=0;i<8;i++)length=(length<<8)|(byte)stream.ReadByte();}var mask=new byte[4];await stream.ReadExactlyAsync(mask);var payload=new byte[(int)length];await stream.ReadExactlyAsync(payload);for(var i=0;i<payload.Length;i++)payload[i]^=mask[i%4];return Encoding.UTF8.GetString(payload);}
    private static async Task WriteServerText(NetworkStream stream,string text)=>await WriteFrame(stream,0x81,Encoding.UTF8.GetBytes(text));
    private static async Task WriteFragmentedUtf8(NetworkStream stream,string text,string splitAt){var payload=Encoding.UTF8.GetBytes(text);var marker=Encoding.UTF8.GetBytes(splitAt);var index=payload.AsSpan().IndexOf(marker);Check(index>=0,"UTF-8 marker missing");await WriteFrame(stream,0x01,payload[..(index+1)]);await WriteFrame(stream,0x80,payload[(index+1)..]);}
    private static async Task WriteFrame(NetworkStream stream,int first,byte[] payload){var header=new List<byte>{(byte)first};if(payload.Length<126)header.Add((byte)payload.Length);else{header.Add(126);header.Add((byte)(payload.Length>>8));header.Add((byte)payload.Length);}await stream.WriteAsync(header.ToArray());await stream.WriteAsync(payload);}
    private static async Task WaitForEof(NetworkStream stream){var buffer=new byte[256];try{while(await stream.ReadAsync(buffer)>0){}}catch(IOException){}}
    private static async Task<JsonNode> ReadEvent(StreamReader reader){var line=await reader.ReadLineAsync().WaitAsync(Timeout);return JsonNode.Parse(line??throw new EndOfStreamException("adapter event stream closed"))!;}
    private static string ReadAsciiLine(NetworkStream stream){var bytes=new List<byte>();while(true){var value=stream.ReadByte();if(value<0)throw new EndOfStreamException();if(value=='\r'){if(stream.ReadByte()!='\n')throw new IOException("invalid line ending");return Encoding.ASCII.GetString(bytes.ToArray());}bytes.Add((byte)value);}}
    private static void Check(bool condition,string message){if(!condition)throw new Exception(message);}
    private static void Equal<T>(T expected,T? actual,string message){if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new Exception($"{message}: expected {expected}, got {actual}");}
}
