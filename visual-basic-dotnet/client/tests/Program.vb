Imports System.Diagnostics
Imports System.IO
Imports System.Net
Imports System.Net.Sockets
Imports System.Security.Cryptography
Imports System.Text
Imports System.Text.Json.Nodes
Imports System.Threading
Imports ConvexVisualBasic
Imports AdapterProgram = Adapter.Program

Module Program
    Private ReadOnly TestTimeout As TimeSpan = TimeSpan.FromSeconds(7)

    Public Sub Main(args As String())
        MainAsync().GetAwaiter().GetResult()
    End Sub

    Private Async Function MainAsync() As Task
        TestBoundedDeliveryNullAndHydration()
        Await TestAdapterValidationNullErrorsAndByteLimit()
        Await TestAdapterStaleRelay(False)
        Await TestAdapterStaleRelay(True)
        Await TestLiveFiveReconnectsAndRecovery()
        Await TestFiveFailedReconnectsThenRecovery()
        Await TestProtocolAndTransportRecovery()
        Await TestBoundedCloseAndHandshake()
        Await TestBoundedWriter()
        Console.WriteLine("Visual Basic .NET adversarial client tests passed")
    End Function

    Private Async Function TestFiveFailedReconnectsThenRecovery() As Task
        Using listener = Listen()
            Dim server = Task.Run(Async Function()
                                      Using initialPeer = Await listener.AcceptTcpClientAsync()
                                          Dim stream = initialPeer.GetStream()
                                          Await Handshake(stream)
                                          Await ReadClientText(stream)
                                          Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Await WriteServerText(stream, Transition(ZeroVersion(), Version(1), Updated(queryId, 0)).ToJsonString())
                                          Await WaitForEof(stream)
                                      End Using

                                      ' Refuse five real WebSocket handshakes. These are transport
                                      ' failures, not a test-only counter or mocked reconnect hook.
                                      For attempt = 1 To 5
                                          Using refused = Await listener.AcceptTcpClientAsync()
                                              Dim stream = refused.GetStream()
                                              Await ReadHeaders(stream)
                                              Dim rejection = "HTTP/1.1 503 Service Unavailable" & vbCrLf & "Content-Length: 0" & vbCrLf & "Connection: close" & vbCrLf & vbCrLf
                                              Await stream.WriteAsync(Encoding.ASCII.GetBytes(rejection))
                                          End Using
                                      Next

                                      Using recovered = Await listener.AcceptTcpClientAsync()
                                          Dim stream = recovered.GetStream()
                                          Await Handshake(stream)
                                          Dim connect = JsonNode.Parse(Await ReadClientText(stream))
                                          Equal(1, connect("connectionCount").GetValue(Of Integer)(), "failed handshakes changed connectionCount")
                                          Equal("TransportError", connect("lastCloseReason").GetValue(Of String)(), "failed reconnect reason")
                                          Equal(Version(1)("ts").GetValue(Of String)(), connect("maxObservedTimestamp").GetValue(Of String)(), "failed reconnect lost timestamp")
                                          Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Await WriteServerText(stream, Transition(ZeroVersion(), Version(6), Updated(queryId, 0), Updated(queryId, 1)).ToJsonString())
                                          Await WaitForEof(stream)
                                      End Using

                                      Using resetProbe = Await listener.AcceptTcpClientAsync()
                                          Dim stream = resetProbe.GetStream()
                                          Await Handshake(stream)
                                          Dim connect = JsonNode.Parse(Await ReadClientText(stream))
                                          Equal(2, connect("connectionCount").GetValue(Of Integer)(), "recovered connection count")
                                          Equal("DebugDisconnect", connect("lastCloseReason").GetValue(Of String)(), "post-recovery disconnect reason")
                                          Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Await WriteServerText(stream, Transition(ZeroVersion(), Version(7), Updated(queryId, 1), Updated(queryId, 2)).ToJsonString())
                                          Await WaitForEof(stream)
                                      End Using
                                      Return True
                                  End Function)

            Using live As New LiveClient(Url(listener))
                Using subscription = Await live.Subscribe("demo:state", New JsonObject())
                    Equal(0, subscription.Next(TestTimeout)("count").GetValue(Of Integer)(), "failed-reconnect initial value")
                    Await live.DebugDisconnect()
                    For attempt = 1 To 5
                        Dim failure = subscription.NextUpdate(TimeSpan.FromSeconds(10))
                        Dim observed = If(failure.Error Is Nothing, "value update", failure.Error.GetType().FullName & ": " & failure.Error.Message)
                        Check(TypeOf failure.Error Is ConvexClient.TransportException,
                            "failed handshake was not TransportError: " & observed)
                    Next
                    Equal(1, subscription.Next(TimeSpan.FromSeconds(10))("count").GetValue(Of Integer)(), "five-failure recovery value")

                    Dim resetTimer = Stopwatch.StartNew()
                    Await live.DebugDisconnect()
                    Equal(2, subscription.Next(TestTimeout)("count").GetValue(Of Integer)(), "post-recovery reconnect value")
                    resetTimer.Stop()
                    Check(resetTimer.Elapsed < TimeSpan.FromSeconds(2), "successful handshake did not reset reconnect backoff")
                End Using
            End Using
            Await server.WaitAsync(TimeSpan.FromSeconds(15))
        End Using
    End Function

    Private Sub TestBoundedDeliveryNullAndHydration()
        Dim nullSubscription = New LiveClient.Subscription(Nothing, 1, "demo:null", New JsonObject())
        nullSubscription.Offer(LiveClient.Update.Success(Nothing, {"null log"}))
        Dim nullUpdate = nullSubscription.NextUpdate(TestTimeout)
        Check(nullUpdate.HasValue AndAlso nullUpdate.Value Is Nothing, "JSON null was not retained as a successful value")
        Equal("null log", nullUpdate.Logs(0), "JSON null logs")

        Dim bounded = New LiveClient.Subscription(Nothing, 2, "demo:state", New JsonObject())
        For value = 0 To 19
            bounded.Offer(LiveClient.Update.Success(New JsonObject From {{"count", value}}, Array.Empty(Of String)()))
        Next
        Equal(4, bounded.Next(TestTimeout)("count").GetValue(Of Integer)(), "newest-16 count bound")

        Dim hydrated = New LiveClient.Subscription(Nothing, 3, "demo:state", New JsonObject())
        hydrated.Offer(LiveClient.Update.Success(New JsonObject From {{"count", 0}}, Array.Empty(Of String)()))
        hydrated.Next(TestTimeout)
        hydrated.BeginHydration()
        hydrated.Offer(LiveClient.Update.Success(New JsonObject From {{"count", 0}}, Array.Empty(Of String)()))
        ExpectTimeout(Function() hydrated.Next(TimeSpan.FromMilliseconds(30)), "unchanged hydration crossed reconnect")
        hydrated.Offer(LiveClient.Update.Success(New JsonObject From {{"count", 1}}, Array.Empty(Of String)()))
        Equal(1, hydrated.Next(TestTimeout)("count").GetValue(Of Integer)(), "changed hydration was suppressed")

        Dim byteBounded = New LiveClient.Subscription(Nothing, 4, "demo:large", New JsonObject())
        Dim nearMaximumLog = New String("雪"c, 400000)
        byteBounded.Offer(LiveClient.Update.Success(New JsonObject From {{"ok", True}}, {nearMaximumLog}))
        Dim oversized = byteBounded.NextUpdate(TestTimeout)
        Check(TypeOf oversized.Error Is ConvexClient.ProtocolException, "encoded logs were omitted from the byte budget")

        ' The adapter permits eight subscriptions. Retain a distinct near-limit value in
        ' every queue, stop consuming, and prove the real CLR process stays below the
        ' shared 128 MiB ceiling rather than treating an event count as a memory bound.
        Dim stoppedReaderQueues As New List(Of LiveClient.Subscription)()
        For subscriptionId = 0 To 7
            Dim payload = subscriptionId.ToString("D2") & New String(ChrW(65 + (subscriptionId Mod 26)), 749998)
            Dim subscription = New LiveClient.Subscription(Nothing, 100 + subscriptionId, "demo:large", New JsonObject())
            subscription.Offer(LiveClient.Update.Success(New JsonObject From {{"payload", payload}}, Array.Empty(Of String)()))
            stoppedReaderQueues.Add(subscription)
        Next
        GC.Collect()
        GC.WaitForPendingFinalizers()
        GC.Collect()
        Dim workingSet = Process.GetCurrentProcess().WorkingSet64
        Check(workingSet < 128L * 1024L * 1024L, "stopped-reader queues exceeded 128 MiB: " & workingSet)
    End Sub

    Private Async Function TestAdapterValidationNullErrorsAndByteLimit() As Task
        Using listener = Listen()
            Dim server = Task.Run(Async Function()
                                      Using first = Await listener.AcceptTcpClientAsync()
                                          Await ReadHttpRequest(first.GetStream())
                                          Await WriteHttpResponse(first.GetStream(), 200, "{""status"":""success"",""value"":null,""logLines"":[]}")
                                      End Using
                                      Using second = Await listener.AcceptTcpClientAsync()
                                          Await ReadHttpRequest(second.GetStream())
                                          Await WriteHttpResponse(second.GetStream(), 560, "{""status"":""error"",""errorMessage"":""empty"",""errorData"":{""code"":""ROOM_EMPTY""},""logLines"":[""checked""]}")
                                      End Using
                                      Using third = Await listener.AcceptTcpClientAsync()
                                          Await ReadHttpRequest(third.GetStream())
                                          Await WriteHttpResponse(third.GetStream(), 200, "[]")
                                      End Using
                                      Using fourth = Await listener.AcceptTcpClientAsync()
                                          Await ReadHttpRequest(fourth.GetStream())
                                          Dim truncated = "HTTP/1.1 200 OK" & vbCrLf & "Content-Type: application/json" & vbCrLf & "Content-Length: 100" & vbCrLf & "Connection: close" & vbCrLf & vbCrLf & "{"
                                          Await fourth.GetStream().WriteAsync(Encoding.ASCII.GetBytes(truncated))
                                      End Using
                                  End Function)
            Dim input = String.Join(ControlChars.Lf, {
                "{""id"":""null"",""op"":""query"",""path"":""demo:null"",""args"":{}}",
                "{""id"":""error"",""op"":""query"",""path"":""demo:error"",""args"":{}}",
                "{""id"":""protocol"",""op"":""query"",""path"":""demo:protocol"",""args"":{}}",
                "{""id"":""transport"",""op"":""query"",""path"":""demo:transport"",""args"":{}}",
                "{""id"":""bad"",""op"":4}",
                "{""id"":""close"",""op"":""close""}"
            }) & ControlChars.Lf
            Dim output As New StringWriter()
            Await AdapterProgram.Run(New StringReader(input), output, Url(listener))
            Await server.WaitAsync(TestTimeout)
            Dim events = ParseEvents(output.ToString())
            Check(events(0).AsObject().ContainsKey("value") AndAlso events(0)("value") Is Nothing, "adapter dropped JSON null")
            Equal("FunctionError", events(1)("error")("name").GetValue(Of String)(), "canonical function error name")
            Equal("ROOM_EMPTY", events(1)("error")("data")("code").GetValue(Of String)(), "structured function data")
            Equal("ProtocolError", events(2)("error")("name").GetValue(Of String)(), "malformed HTTP protocol error name")
            Equal("TransportError", events(3)("error")("name").GetValue(Of String)(), "truncated HTTP transport error name")
            Equal("ProtocolError", events(4)("error")("name").GetValue(Of String)(), "invalid operation protocol error name")
            Equal("closed", events(5)("type").GetValue(Of String)(), "adapter close")
        End Using

        Dim tooLarge = "{""id"":""x"",""op"":""close"",""padding"":""" & New String("雪"c, 350000) & """}" & ControlChars.Lf
        Dim byteOutput As New StringWriter()
        Await AdapterProgram.Run(New StringReader(tooLarge), byteOutput, Nothing)
        Dim byteEvent = ParseEvents(byteOutput.ToString()).Single()
        Equal("ProtocolError", byteEvent("error")("name").GetValue(Of String)(), "UTF-8 byte-limit classification")
        Check(byteEvent("error")("message").GetValue(Of String)().Contains("UTF-8"), "limit counted characters instead of UTF-8 bytes")
    End Function

    Private Async Function TestAdapterStaleRelay(replace As Boolean) As Task
        Using listener = Listen()
            Dim oldTransitionSent = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Dim server = Task.Run(Async Function()
                                      Using peer = Await listener.AcceptTcpClientAsync()
                                          Dim stream = peer.GetStream()
                                          Await Handshake(stream)
                                          Await ReadClientText(stream)
                                          Dim oldAdd = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim oldId = oldAdd("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Await WriteServerText(stream, Transition(ZeroVersion(), Version(1), Updated(oldId, 99)).ToJsonString())
                                          oldTransitionSent.TrySetResult(True)
                                          Dim remove = JsonNode.Parse(Await ReadClientText(stream))
                                          Equal("Remove", remove("modifications")(0)("type").GetValue(Of String)(), "stale-relay Remove")
                                          If replace Then
                                              Dim newAdd = JsonNode.Parse(Await ReadClientText(stream))
                                              Dim newId = newAdd("modifications")(0)("queryId").GetValue(Of Integer)()
                                              Await WriteServerText(stream, Transition(Version(1), Version(2), Updated(newId, 1)).ToJsonString())
                                          End If
                                          Await WaitForEof(stream)
                                      End Using
                                  End Function)

            Dim relayEntered = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Dim releaseRelay = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Dim calls As Integer
            AdapterProgram.RelayBeforeWriter = Async Function()
                                                   If Interlocked.Increment(calls) = 1 Then
                                                       relayEntered.TrySetResult(True)
                                                       Await releaseRelay.Task
                                                   End If
                                               End Function

            Dim input As New QueuedTextReader()
            Dim output As New RecordingTextWriter()
            Dim adapter = AdapterProgram.Run(input, output, Url(listener))
            input.Enqueue("{""id"":""s1"",""op"":""subscribe"",""subscriptionId"":""same"",""path"":""demo:state"",""args"":{}}")
            Await output.WaitForCount(1)
            Await oldTransitionSent.Task.WaitAsync(TestTimeout)
            Await relayEntered.Task.WaitAsync(TestTimeout)
            If replace Then
                input.Enqueue("{""id"":""s2"",""op"":""subscribe"",""subscriptionId"":""same"",""path"":""demo:state"",""args"":{}}")
            Else
                input.Enqueue("{""id"":""u"",""op"":""unsubscribe"",""subscriptionId"":""same""}")
            End If
            Await output.WaitForCount(2)
            releaseRelay.TrySetResult(True)
            If replace Then Await output.WaitForCount(3)
            Await Task.Delay(100)
            Dim events = output.Events()
            Check(Not events.Any(Function(item) HasCount(item, 99)), "stale relay crossed acknowledgement")
            input.Enqueue("{""id"":""close"",""op"":""close""}")
            input.Complete()
            Await adapter.WaitAsync(TestTimeout)
            Await server.WaitAsync(TestTimeout)
            AdapterProgram.RelayBeforeWriter = Nothing
        End Using
    End Function

    Private Async Function TestLiveFiveReconnectsAndRecovery() As Task
        Using listener = Listen()
            Dim server = Task.Run(Async Function()
                                      Dim currentCount = 0
                                      Dim previousTimestamp As String = Nothing
                                      For connection = 0 To 5
                                          Using peer = Await listener.AcceptTcpClientAsync()
                                              Dim stream = peer.GetStream()
                                              Await Handshake(stream)
                                              Dim connect = JsonNode.Parse(Await ReadClientText(stream))
                                              Equal(connection, connect("connectionCount").GetValue(Of Integer)(), "connectionCount")
                                              Equal(If(connection = 0, "InitialConnect", "DebugDisconnect"), connect("lastCloseReason").GetValue(Of String)(), "lastCloseReason")
                                              If previousTimestamp IsNot Nothing Then Equal(previousTimestamp, connect("maxObservedTimestamp").GetValue(Of String)(), "maxObservedTimestamp")
                                              Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                              Equal("Add", add("modifications")(0)("type").GetValue(Of String)(), "reconnect did not resend Add")
                                              Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                              If connection = 0 Then
                                                  Dim initial = Transition(ZeroVersion(), Version(1), Updated(queryId, 0, "雪"))
                                                  Await WriteFragmentedUtf8WithPing(stream, initial.ToJsonString(), "雪")
                                                  previousTimestamp = Version(1)("ts").GetValue(Of String)()
                                                  Await WriteServerText(stream, Transition(Version(1), Version(2), Failed(queryId)).ToJsonString())
                                                  Await WriteServerText(stream, Transition(Version(2), Version(3), Updated(queryId, 1)).ToJsonString())
                                                  currentCount = 1
                                                  previousTimestamp = Version(3)("ts").GetValue(Of String)()
                                              Else
                                                  Dim nextCount = currentCount + 1
                                                  Dim serverTransition = Transition(ZeroVersion(), Version(10 + connection), Updated(queryId, currentCount), Updated(queryId, nextCount))
                                                  Await WriteServerText(stream, serverTransition.ToJsonString())
                                                  currentCount = nextCount
                                                  previousTimestamp = Version(10 + connection)("ts").GetValue(Of String)()
                                              End If
                                              Await WaitForEof(stream)
                                          End Using
                                      Next
                                      Return True
                                  End Function)

            Using live As New LiveClient(Url(listener))
                Using subscription = Await live.Subscribe("demo:state", New JsonObject())
                    Dim initial = subscription.Next(TestTimeout)
                    Equal(0, initial("count").GetValue(Of Integer)(), "initial QueryUpdated")
                    Equal("雪", initial("text").GetValue(Of String)(), "fragmented UTF-8")
                    Dim failedUpdate = subscription.NextUpdate(TestTimeout)
                    Check(TypeOf failedUpdate.Error Is ConvexClient.FunctionException,
                        "QueryFailed classification: " & If(failedUpdate.Error?.GetType().FullName & ": " & failedUpdate.Error.Message, "value update"))
                    Equal("ROOM_EMPTY", DirectCast(failedUpdate.Error, ConvexClient.FunctionException).ErrorData("code").GetValue(Of String)(), "QueryFailed data")
                    Equal(1, subscription.Next(TestTimeout)("count").GetValue(Of Integer)(), "QueryFailed recovery")
                    For expected = 2 To 6
                        Await live.DebugDisconnect()
                        Equal(expected, subscription.Next(TestTimeout)("count").GetValue(Of Integer)(), "five reconnect delivery")
                    Next
                End Using
            End Using
            Await server.WaitAsync(TestTimeout)
        End Using
    End Function

    Private Async Function TestProtocolAndTransportRecovery() As Task
        Using listener = Listen()
            Dim server = Task.Run(Async Function()
                                      Using first = Await listener.AcceptTcpClientAsync()
                                          Dim stream = first.GetStream()
                                          Await Handshake(stream)
                                          Await ReadClientText(stream)
                                          Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Dim invalidEnd As New JsonObject From {{"querySet", 0}, {"identity", 0}, {"ts", "bad"}}
                                          Await WriteServerText(stream, Transition(ZeroVersion(), invalidEnd, Updated(queryId, 99)).ToJsonString())
                                          Await WaitForEof(stream)
                                      End Using
                                      Using second = Await listener.AcceptTcpClientAsync()
                                          Dim stream = second.GetStream()
                                          Await Handshake(stream)
                                          Dim connect = JsonNode.Parse(Await ReadClientText(stream))
                                          Equal("ProtocolError", connect("lastCloseReason").GetValue(Of String)(), "protocol reconnect reason")
                                          Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Await WriteServerText(stream, Transition(ZeroVersion(), Version(2), UpdatedNull(queryId)).ToJsonString())
                                          Await Task.Delay(50)
                                          second.Client.LingerState = New LingerOption(True, 0)
                                      End Using
                                      Using third = Await listener.AcceptTcpClientAsync()
                                          Dim stream = third.GetStream()
                                          Await Handshake(stream)
                                          Dim connect = JsonNode.Parse(Await ReadClientText(stream))
                                          Equal("TransportError", connect("lastCloseReason").GetValue(Of String)(), "transport reconnect reason")
                                          Dim add = JsonNode.Parse(Await ReadClientText(stream))
                                          Dim queryId = add("modifications")(0)("queryId").GetValue(Of Integer)()
                                          Await WriteServerText(stream, Transition(ZeroVersion(), Version(3), Updated(queryId, 1)).ToJsonString())
                                          Await WaitForEof(stream)
                                      End Using
                                  End Function)

            Using live As New LiveClient(Url(listener))
                Using subscription = Await live.Subscribe("demo:state", New JsonObject())
                    Dim protocol = subscription.NextUpdate(TestTimeout)
                    Check(TypeOf protocol.Error Is ConvexClient.ProtocolException, "protocol error classification")
                    Dim nullValue = subscription.NextUpdate(TestTimeout)
                    Check(nullValue.HasValue AndAlso nullValue.Value Is Nothing, "null recovery value")
                    Dim transport = subscription.NextUpdate(TestTimeout)
                    Check(TypeOf transport.Error Is ConvexClient.TransportException, "transport error classification")
                    Equal(1, subscription.Next(TestTimeout)("count").GetValue(Of Integer)(), "transport recovery")
                End Using
            End Using
            Await server.WaitAsync(TestTimeout)
        End Using
    End Function

    Private Async Function TestBoundedCloseAndHandshake() As Task
        Using listener = Listen()
            Dim partialSent = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Dim server = Task.Run(Async Function()
                                      Using peer = Await listener.AcceptTcpClientAsync()
                                          Dim stream = peer.GetStream()
                                          Await Handshake(stream)
                                          Await ReadClientText(stream)
                                          Await ReadClientText(stream)
                                          Await WriteFrame(stream, &H1, Encoding.UTF8.GetBytes("{""type"":""Transition"""))
                                          partialSent.TrySetResult(True)
                                          Await WaitForEof(stream)
                                      End Using
                                  End Function)
            Dim live As New LiveClient(Url(listener))
            Dim subscription = Await live.Subscribe("demo:state", New JsonObject())
            Await partialSent.Task.WaitAsync(TestTimeout)
            Dim closeTimer = Diagnostics.Stopwatch.StartNew()
            Dim firstClose = live.CloseAsync()
            Dim secondClose = live.CloseAsync()
            Await Task.WhenAll(firstClose, secondClose).WaitAsync(TimeSpan.FromSeconds(2))
            closeTimer.Stop()
            Check(closeTimer.Elapsed < TimeSpan.FromSeconds(2), "concurrent close stalled behind a partial frame")
            subscription.Dispose()
            Await server.WaitAsync(TestTimeout)
        End Using

        Using listener = Listen()
            Dim sending = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Dim server = Task.Run(Async Function()
                                      Using peer = Await listener.AcceptTcpClientAsync()
                                          Dim stream = peer.GetStream()
                                          Await Handshake(stream)
                                          Await ReadClientText(stream)
                                          Await ReadClientText(stream)
                                          Try
                                              While True
                                                  sending.TrySetResult(True)
                                                  Await WriteServerText(stream, "{""type"":""Ping""}")
                                              End While
                                          Catch ex As IOException
                                          End Try
                                      End Using
                                      Return True
                                  End Function)
            Using live As New LiveClient(Url(listener))
                Dim subscription = Await live.Subscribe("demo:state", New JsonObject())
                Await sending.Task.WaitAsync(TestTimeout)
                Dim unsubscribeTimer = Stopwatch.StartNew()
                subscription.Dispose()
                unsubscribeTimer.Stop()
                Check(unsubscribeTimer.Elapsed < TimeSpan.FromSeconds(2), "unsubscribe stalled behind continuous frames")
                Await live.CloseAsync().WaitAsync(TimeSpan.FromSeconds(2))
            End Using
            Await server.WaitAsync(TestTimeout)
        End Using

        Using listener = Listen()
            Dim server = Task.Run(Async Function()
                                      Using peer = Await listener.AcceptTcpClientAsync()
                                          Await Task.Delay(TimeSpan.FromSeconds(5))
                                      End Using
                                  End Function)
            Using live As New LiveClient(Url(listener))
                Dim handshakeTimer = Diagnostics.Stopwatch.StartNew()
                Try
                    Await live.Subscribe("demo:state", New JsonObject())
                    Throw New Exception("stalled handshake became a subscription")
                Catch ex As ConvexClient.TransportException
                End Try
                handshakeTimer.Stop()
                Check(handshakeTimer.Elapsed < TimeSpan.FromSeconds(4), "stalled handshake was unbounded")
            End Using
            Await server.WaitAsync(TimeSpan.FromSeconds(7))
        End Using
    End Function

    Private Async Function TestBoundedWriter() As Task
        Dim writer = New AdapterProgram.LockedWriter(New StalledTextWriter())
        Dim writeTimer = Diagnostics.Stopwatch.StartNew()
        Try
            Await writer.WriteAsync(New JsonObject From {{"type", "closed"}, {"id", "x"}})
            Throw New Exception("stalled output write completed")
        Catch ex As IOException
        End Try
        writeTimer.Stop()
        Check(writeTimer.Elapsed < TimeSpan.FromSeconds(4), "adapter output write was unbounded")
    End Function

    Private Function HasCount(item As JsonNode, expected As Integer) As Boolean
        Dim value = TryCast(item("value"), JsonObject)
        If value Is Nothing OrElse value("count") Is Nothing Then Return False
        Return value("count").GetValue(Of Integer)() = expected
    End Function

    Private Function Listen() As TcpListener
        Dim listener As New TcpListener(IPAddress.Loopback, 0)
        listener.Start()
        Return listener
    End Function

    Private Function Url(listener As TcpListener) As String
        Return "http://127.0.0.1:" & DirectCast(listener.LocalEndpoint, IPEndPoint).Port
    End Function

    Private Function ZeroVersion() As JsonObject
        Return Version(0)
    End Function

    Private Function Version(value As Long) As JsonObject
        Return New JsonObject From {
            {"querySet", 0}, {"identity", 0}, {"ts", Convert.ToBase64String(BitConverter.GetBytes(value))}
        }
    End Function

    Private Function Updated(queryId As Integer, count As Integer, Optional text As String = Nothing) As JsonObject
        Dim value As New JsonObject From {{"count", count}}
        If text IsNot Nothing Then value("text") = text
        Return New JsonObject From {{"type", "QueryUpdated"}, {"queryId", queryId}, {"value", value}, {"logLines", New JsonArray()}}
    End Function

    Private Function UpdatedNull(queryId As Integer) As JsonObject
        Return New JsonObject From {{"type", "QueryUpdated"}, {"queryId", queryId}, {"value", Nothing}, {"logLines", New JsonArray()}}
    End Function

    Private Function Failed(queryId As Integer) As JsonObject
        Return New JsonObject From {
            {"type", "QueryFailed"}, {"queryId", queryId}, {"errorMessage", "empty"},
            {"errorData", New JsonObject From {{"code", "ROOM_EMPTY"}}}, {"logLines", New JsonArray("checked")}
        }
    End Function

    Private Function Transition(startVersion As JsonObject, endVersion As JsonObject, ParamArray modifications As JsonObject()) As JsonObject
        Dim values As New JsonArray()
        For Each modification In modifications
            values.Add(modification)
        Next
        Return New JsonObject From {{"type", "Transition"}, {"startVersion", startVersion}, {"endVersion", endVersion}, {"modifications", values}}
    End Function

    Private Async Function Handshake(stream As NetworkStream) As Task
        Dim request = Await ReadHeaders(stream)
        Dim key = request.Split({ControlChars.Cr & ControlChars.Lf}, StringSplitOptions.None).
            First(Function(line) line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)).Split(":"c, 2)(1).Trim()
        Dim accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
        Dim response = "HTTP/1.1 101 Switching Protocols" & vbCrLf & "Upgrade: websocket" & vbCrLf & "Connection: Upgrade" & vbCrLf & "Sec-WebSocket-Accept: " & accept & vbCrLf & vbCrLf
        Await stream.WriteAsync(Encoding.ASCII.GetBytes(response))
    End Function

    Private Async Function ReadHeaders(stream As NetworkStream) As Task(Of String)
        Dim bytes As New List(Of Byte)()
        Dim matched As Integer
        While matched < 4
            Dim value = stream.ReadByte()
            If value < 0 Then Throw New EndOfStreamException()
            bytes.Add(CByte(value))
            If matched = 0 AndAlso value = 13 Then
                matched = 1
            ElseIf matched = 1 AndAlso value = 10 Then
                matched = 2
            ElseIf matched = 2 AndAlso value = 13 Then
                matched = 3
            ElseIf matched = 3 AndAlso value = 10 Then
                matched = 4
            Else
                matched = 0
            End If
        End While
        Return Await Task.FromResult(Encoding.ASCII.GetString(bytes.ToArray()))
    End Function

    Private Async Function ReadClientText(stream As NetworkStream) As Task(Of String)
        Dim first = stream.ReadByte()
        Dim second = stream.ReadByte()
        If first < 0 OrElse second < 0 Then Throw New EndOfStreamException()
        Dim length As Long = second And 127
        If length = 126 Then
            length = (CLng(CByte(stream.ReadByte())) << 8) Or CByte(stream.ReadByte())
        ElseIf length = 127 Then
            length = 0
            For index = 0 To 7
                length = (length << 8) Or CByte(stream.ReadByte())
            Next
        End If
        Dim mask(3) As Byte
        Await ReadExactly(stream, mask)
        Dim payload(CInt(length) - 1) As Byte
        Await ReadExactly(stream, payload)
        For index = 0 To payload.Length - 1
            payload(index) = payload(index) Xor mask(index Mod 4)
        Next
        Return Encoding.UTF8.GetString(payload)
    End Function

    Private Async Function WriteServerText(stream As NetworkStream, text As String) As Task
        Await WriteFrame(stream, &H81, Encoding.UTF8.GetBytes(text))
    End Function

    Private Async Function WriteFragmentedUtf8WithPing(stream As NetworkStream, text As String, marker As String) As Task
        ' System.Text.Json escapes non-ASCII by default. Replace this fixture marker so
        ' the wire message really does split in the middle of a multi-byte code point.
        text = text.Replace("\u96EA", marker, StringComparison.OrdinalIgnoreCase)
        Dim payload = Encoding.UTF8.GetBytes(text)
        Dim markerBytes = Encoding.UTF8.GetBytes(marker)
        Dim split = FindBytes(payload, markerBytes) + 1
        Check(split > 0, "UTF-8 marker missing")
        Await WriteFrame(stream, &H1, payload.Take(split).ToArray())
        Await WriteFrame(stream, &H89, Encoding.ASCII.GetBytes("p"))
        Await WriteFrame(stream, &H80, payload.Skip(split).ToArray())
    End Function

    Private Function FindBytes(haystack As Byte(), needle As Byte()) As Integer
        For index = 0 To haystack.Length - needle.Length
            Dim matches = True
            For offset = 0 To needle.Length - 1
                If haystack(index + offset) <> needle(offset) Then matches = False
            Next
            If matches Then Return index
        Next
        Return -1
    End Function

    Private Async Function WriteFrame(stream As NetworkStream, first As Integer, payload As Byte()) As Task
        Dim header As New List(Of Byte) From {CByte(first)}
        If payload.Length < 126 Then
            header.Add(CByte(payload.Length))
        ElseIf payload.Length <= UShort.MaxValue Then
            header.Add(126)
            header.Add(CByte((payload.Length >> 8) And &HFF))
            header.Add(CByte(payload.Length And &HFF))
        Else
            header.Add(127)
            For shift = 56 To 0 Step -8
                header.Add(CByte((CLng(payload.Length) >> shift) And &HFF))
            Next
        End If
        Await stream.WriteAsync(header.ToArray())
        Await stream.WriteAsync(payload)
    End Function

    Private Async Function WaitForEof(stream As NetworkStream) As Task
        Dim buffer(255) As Byte
        Try
            While Await stream.ReadAsync(buffer) > 0
            End While
        Catch ex As IOException
        End Try
    End Function

    Private Async Function ReadExactly(stream As Stream, buffer As Byte()) As Task
        Dim offset As Integer
        While offset < buffer.Length
            Dim count = Await stream.ReadAsync(buffer, offset, buffer.Length - offset)
            If count = 0 Then Throw New EndOfStreamException()
            offset += count
        End While
    End Function

    Private Async Function ReadHttpRequest(stream As NetworkStream) As Task(Of String)
        Dim headers = Await ReadHeaders(stream)
        Dim contentLength As Integer
        For Each line In headers.Split({vbCrLf}, StringSplitOptions.None)
            If line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase) Then contentLength = Integer.Parse(line.Split(":"c)(1).Trim())
        Next
        Dim body(Math.Max(0, contentLength) - 1) As Byte
        If contentLength > 0 Then Await ReadExactly(stream, body)
        Return headers & Encoding.UTF8.GetString(body)
    End Function

    Private Async Function WriteHttpResponse(stream As NetworkStream, status As Integer, body As String) As Task
        Dim payload = Encoding.UTF8.GetBytes(body)
        Dim headers = Encoding.ASCII.GetBytes("HTTP/1.1 " & status & " Test" & vbCrLf & "Content-Type: application/json" & vbCrLf & "Content-Length: " & payload.Length & vbCrLf & "Connection: close" & vbCrLf & vbCrLf)
        Await stream.WriteAsync(headers)
        Await stream.WriteAsync(payload)
    End Function

    Private Function ParseEvents(output As String) As JsonNode()
        Return output.Split(ControlChars.Lf, StringSplitOptions.RemoveEmptyEntries).Select(Function(line) JsonNode.Parse(line)).ToArray()
    End Function

    Private Sub ExpectTimeout(action As Func(Of JsonNode), message As String)
        Try
            action()
            Throw New Exception(message)
        Catch ex As TimeoutException
        End Try
    End Sub

    Private Sub Check(condition As Boolean, message As String)
        If Not condition Then Throw New Exception(message)
    End Sub

    Private Sub Equal(Of T)(expected As T, actual As T, message As String)
        If Not EqualityComparer(Of T).Default.Equals(expected, actual) Then Throw New Exception(message & ": values differ")
    End Sub

    Private NotInheritable Class QueuedTextReader
        Inherits TextReader
        Private ReadOnly characters As Channels.Channel(Of Char) = Channels.Channel.CreateUnbounded(Of Char)()
        Public Sub Enqueue(line As String)
            For Each character In line & ControlChars.Lf
                characters.Writer.TryWrite(character)
            Next
        End Sub
        Public Sub Complete()
            characters.Writer.TryComplete()
        End Sub
        Public Overrides Async Function ReadAsync(buffer As Char(), index As Integer, count As Integer) As Task(Of Integer)
            If Not Await characters.Reader.WaitToReadAsync() Then Return 0
            Dim character As Char
            If Not characters.Reader.TryRead(character) Then Return 0
            buffer(index) = character
            Return 1
        End Function
    End Class

    Private NotInheritable Class RecordingTextWriter
        Inherits StringWriter
        Private ReadOnly changed As New SemaphoreSlim(0)
        Public Overrides Function WriteLineAsync(value As ReadOnlyMemory(Of Char), Optional cancellationToken As CancellationToken = Nothing) As Task
            MyBase.WriteLine(value.Span.ToString())
            changed.Release()
            Return Task.CompletedTask
        End Function
        Public Async Function WaitForCount(count As Integer) As Task
            While Events().Length < count
                Await changed.WaitAsync(TestTimeout)
            End While
        End Function
        Public Function Events() As JsonNode()
            Return ParseEvents(ToString())
        End Function
    End Class

    Private NotInheritable Class StalledTextWriter
        Inherits TextWriter
        Public Overrides ReadOnly Property Encoding As Encoding = Encoding.UTF8
        Public Overrides Function WriteLineAsync(value As ReadOnlyMemory(Of Char), Optional cancellationToken As CancellationToken = Nothing) As Task
            Return Task.Delay(Timeout.Infinite, cancellationToken)
        End Function
    End Class
End Module
