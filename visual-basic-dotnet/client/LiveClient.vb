Imports System.IO
Imports System.Net.WebSockets
Imports System.Text
Imports System.Text.Json.Nodes
Imports System.Threading
Imports System.Threading.Channels

Namespace ConvexVisualBasic
    ''' <summary>
    ''' Native owner-loop implementation of the pinned convex-rs 0.10.4 /api/sync profile.
    ''' Only OwnerLoop starts reads, writes frames, changes query-set versions, reconnects,
    ''' or disposes sockets. Public methods submit commands and wait for its acknowledgement.
    ''' </summary>
    Public NotInheritable Class LiveClient
        Implements IDisposable

        Private Const MaxFrameBytes As Integer = 1048576
        Private Const MaxSubscriptions As Integer = 8
        Private Shared ReadOnly StrictUtf8 As New UTF8Encoding(False, True)

        Private ReadOnly endpoint As Uri
        Private ReadOnly commands As Channel(Of OwnerCommand)
        Private ReadOnly ownerTask As Task
        Private ReadOnly subscriptions As New Dictionary(Of Integer, Subscription)()
        Private ReadOnly lifetime As New CancellationTokenSource()
        Private ReadOnly closeCompletion As New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
        Private closeRequested As Integer

        ' The fields below are owned exclusively by OwnerLoop.
        Private socket As ClientWebSocket
        Private receiveSocket As ClientWebSocket
        Private receiveTask As Task(Of WebSocketReceiveResult)
        Private ReadOnly receiveBuffer(MaxFrameBytes - 1) As Byte
        Private ReadOnly frame As New MemoryStream()
        Private nextId As Integer
        Private querySet As Integer
        Private connectionCount As Integer
        Private lastCloseReason As String = "InitialConnect"
        Private maxObservedTimestamp As String
        Private version As JsonObject = ZeroVersion()
        Private reconnectDelayMilliseconds As Integer = 100
        Private reconnectAt As DateTimeOffset?
        Private connectionGeneration As Long
        Private closed As Boolean

        Public Sub New(deployment As String)
            Dim baseUri As New Uri(deployment.TrimEnd("/"c))
            If baseUri.Scheme <> Uri.UriSchemeHttp AndAlso baseUri.Scheme <> Uri.UriSchemeHttps Then
                Throw New ArgumentException("Convex deployment URL must use http or https")
            End If
            endpoint = New UriBuilder(baseUri) With {
                .Scheme = If(baseUri.Scheme = Uri.UriSchemeHttps, "wss", "ws"),
                .Path = baseUri.AbsolutePath.TrimEnd("/"c) & "/api/sync"
            }.Uri
            commands = Channel.CreateBounded(Of OwnerCommand)(New BoundedChannelOptions(64) With {
                .FullMode = BoundedChannelFullMode.Wait,
                .SingleReader = True,
                .SingleWriter = False,
                .AllowSynchronousContinuations = False
            })
            ownerTask = OwnerLoop()
        End Sub

        Public Async Function Subscribe(path As String, args As JsonObject) As Task(Of Subscription)
            If String.IsNullOrWhiteSpace(path) Then Throw New ArgumentException("Convex function path is required")
            If args Is Nothing Then Throw New ArgumentNullException(NameOf(args))
            Dim completion = New TaskCompletionSource(Of Subscription)(TaskCreationOptions.RunContinuationsAsynchronously)
            Await Submit(New SubscribeCommand(path, DirectCast(args.DeepClone(), JsonObject), completion)).ConfigureAwait(False)
            Return Await completion.Task.ConfigureAwait(False)
        End Function

        Friend Async Function Unsubscribe(subscription As Subscription) As Task
            If subscription Is Nothing Then Return
            Dim completion = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Await Submit(New UnsubscribeCommand(subscription, completion)).ConfigureAwait(False)
            Await completion.Task.ConfigureAwait(False)
        End Function

        Public Async Function DebugDisconnect() As Task
            Dim completion = New TaskCompletionSource(Of Boolean)(TaskCreationOptions.RunContinuationsAsynchronously)
            Await Submit(New DebugDisconnectCommand(completion)).ConfigureAwait(False)
            Await completion.Task.ConfigureAwait(False)
        End Function

        Public Async Function CloseAsync() As Task
            If Interlocked.CompareExchange(closeRequested, 1, 0) = 0 Then
                Try
                    Await Submit(New CloseCommand(closeCompletion)).ConfigureAwait(False)
                Catch ex As Exception
                    closeCompletion.TrySetException(ex)
                End Try
            End If
            Await closeCompletion.Task.WaitAsync(TimeSpan.FromSeconds(7)).ConfigureAwait(False)
            Await ownerTask.WaitAsync(TimeSpan.FromSeconds(7)).ConfigureAwait(False)
        End Function

        Private Async Function Submit(command As OwnerCommand) As Task
            If closed Then Throw New ObjectDisposedException(NameOf(LiveClient))
            Using bounded As New CancellationTokenSource(TimeSpan.FromSeconds(3))
                Try
                    Await commands.Writer.WriteAsync(command, bounded.Token).ConfigureAwait(False)
                Catch ex As ChannelClosedException
                    Throw New ObjectDisposedException(NameOf(LiveClient))
                End Try
            End Using
        End Function

        Private Async Function OwnerLoop() As Task
            Dim commandReady As Task(Of Boolean) = Nothing
            Try
                While Not closed
                    If socket IsNot Nothing AndAlso receiveTask Is Nothing Then
                        receiveSocket = socket
                        receiveTask = socket.ReceiveAsync(receiveBuffer, lifetime.Token)
                    End If

                    If commandReady Is Nothing Then commandReady = commands.Reader.WaitToReadAsync(lifetime.Token).AsTask()
                    Dim reconnectReady As Task = Nothing
                    If socket Is Nothing AndAlso subscriptions.Count > 0 AndAlso reconnectAt.HasValue Then
                        Dim remaining = reconnectAt.Value - DateTimeOffset.UtcNow
                        reconnectReady = Task.Delay(If(remaining > TimeSpan.Zero, remaining, TimeSpan.Zero), lifetime.Token)
                    End If

                    Dim completed As Task
                    If receiveTask Is Nothing Then
                        If reconnectReady Is Nothing Then
                            Await commandReady.ConfigureAwait(False)
                            completed = commandReady
                        Else
                            completed = Await Task.WhenAny(commandReady, reconnectReady).ConfigureAwait(False)
                        End If
                    Else
                        If reconnectReady Is Nothing Then
                            completed = Await Task.WhenAny(commandReady, receiveTask).ConfigureAwait(False)
                        Else
                            completed = Await Task.WhenAny(commandReady, receiveTask, reconnectReady).ConfigureAwait(False)
                        End If
                    End If

                    ' Commands win ties, which keeps unsubscribe, close, and debug disconnect bounded.
                    Dim command As OwnerCommand = Nothing
                    If commandReady.IsCompletedSuccessfully AndAlso commandReady.Result AndAlso commands.Reader.TryRead(command) Then
                        commandReady = Nothing
                        Await HandleCommand(command).ConfigureAwait(False)
                        Continue While
                    End If

                    If receiveTask IsNot Nothing AndAlso receiveTask.IsCompleted Then
                        Dim finishedReceive = receiveTask
                        Dim expectedSocket = receiveSocket
                        receiveTask = Nothing
                        receiveSocket = Nothing
                        Await HandleReceive(expectedSocket, finishedReceive).ConfigureAwait(False)
                        Continue While
                    End If

                    If reconnectReady IsNot Nothing AndAlso completed Is reconnectReady AndAlso socket Is Nothing AndAlso subscriptions.Count > 0 Then
                        reconnectAt = Nothing
                        Await TryConnect(False).ConfigureAwait(False)
                    End If
                End While
            Catch ex As OperationCanceledException When closed
            Finally
                commands.Writer.TryComplete()
                Dim abandoned As OwnerCommand = Nothing
                While commands.Reader.TryRead(abandoned)
                    abandoned.Fail(New ObjectDisposedException(NameOf(LiveClient)))
                End While
                AbortSocket("ClientClosed", False)
                For Each subscription In subscriptions.Values
                    subscription.Finish()
                Next
                subscriptions.Clear()
            End Try
        End Function

        Private Async Function HandleCommand(command As OwnerCommand) As Task
            Try
                If TypeOf command Is SubscribeCommand Then
                    Dim subscribe = DirectCast(command, SubscribeCommand)
                    If subscriptions.Count >= MaxSubscriptions Then Throw New InvalidOperationException("Live subscription limit is 8")
                    Dim subscription = New Subscription(Me, nextId, subscribe.Path, subscribe.Args)
                    nextId += 1
                    subscriptions.Add(subscription.QueryId, subscription)
                    Try
                        If socket Is Nothing Then
                            Await TryConnect(True).ConfigureAwait(False)
                        Else
                            Await Modify({Add(subscription)}).ConfigureAwait(False)
                        End If
                        subscribe.Completion.TrySetResult(subscription)
                    Catch
                        subscriptions.Remove(subscription.QueryId)
                        subscription.Finish()
                        Throw
                    End Try
                    Return
                End If

                If TypeOf command Is UnsubscribeCommand Then
                    Dim unsubscribe = DirectCast(command, UnsubscribeCommand)
                    Dim current As Subscription = Nothing
                    If subscriptions.TryGetValue(unsubscribe.Subscription.QueryId, current) AndAlso
                        Object.ReferenceEquals(current, unsubscribe.Subscription) Then
                        subscriptions.Remove(current.QueryId)
                        current.Finish()
                        If socket IsNot Nothing Then Await Modify({Remove(current.QueryId)}).ConfigureAwait(False)
                    End If
                    unsubscribe.Completion.TrySetResult(True)
                    Return
                End If

                If TypeOf command Is DebugDisconnectCommand Then
                    If socket Is Nothing Then Throw New InvalidOperationException("Live WebSocket is not connected")
                    AbortSocket("DebugDisconnect", True)
                    DirectCast(command, DebugDisconnectCommand).Completion.TrySetResult(True)
                    Return
                End If

                If TypeOf command Is CloseCommand Then
                    closed = True
                    reconnectAt = Nothing
                    AbortSocket("ClientClosed", False)
                    For Each subscription In subscriptions.Values
                        subscription.Finish()
                    Next
                    subscriptions.Clear()
                    DirectCast(command, CloseCommand).Completion.TrySetResult(True)
                    lifetime.Cancel()
                    Return
                End If

                Throw New ConvexClient.ProtocolException("unknown Live owner command")
            Catch ex As Exception
                command.Fail(ex)
            End Try
        End Function

        Private Async Function TryConnect(failCaller As Boolean) As Task
            Dim connecting As New ClientWebSocket()
            connecting.Options.SetRequestHeader("Convex-Client", "visual-basic-dotnet-0.2.0")
            Try
                Using bounded = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                    bounded.CancelAfter(TimeSpan.FromSeconds(3))
                    Await connecting.ConnectAsync(endpoint, bounded.Token).ConfigureAwait(False)
                End Using
                socket = connecting
                connectionGeneration += 1
                querySet = 0
                version = ZeroVersion()
                frame.SetLength(0)
                reconnectAt = Nothing
                reconnectDelayMilliseconds = 100

                Dim connect As New JsonObject From {
                    {"type", "Connect"},
                    {"sessionId", Guid.NewGuid().ToString()},
                    {"connectionCount", connectionCount},
                    {"lastCloseReason", lastCloseReason},
                    {"clientTs", 0}
                }
                If maxObservedTimestamp IsNot Nothing Then connect("maxObservedTimestamp") = maxObservedTimestamp
                Await Send(connect).ConfigureAwait(False)
                If subscriptions.Count > 0 Then
                    For Each subscription In subscriptions.Values
                        subscription.BeginHydration()
                    Next
                    Await Modify(subscriptions.Values.OrderBy(Function(value) value.QueryId).Select(Function(value) Add(value))).ConfigureAwait(False)
                End If
            Catch ex As Exception
                Dim failure As New ConvexClient.TransportException("live", ex)
                If Object.ReferenceEquals(socket, connecting) Then
                    ' The WebSocket handshake completed, so retiring this installed
                    ' connection must advance connectionCount like every other close.
                    AbortSocket("TransportError", True)
                Else
                    connecting.Abort()
                    connecting.Dispose()
                    ScheduleReconnect("TransportError")
                End If
                If failCaller Then Throw failure
                DeliverFailure(failure)
            End Try
        End Function

        Private Async Function HandleReceive(expectedSocket As ClientWebSocket, pending As Task(Of WebSocketReceiveResult)) As Task
            Dim result As WebSocketReceiveResult
            Try
                result = Await pending.ConfigureAwait(False)
            Catch ex As OperationCanceledException When closed
                Return
            Catch ex As Exception
                If Object.ReferenceEquals(socket, expectedSocket) Then
                    Dim failure As New ConvexClient.TransportException("live", ex)
                    DeliverFailure(failure)
                    AbortSocket("TransportError", True)
                End If
                Return
            End Try

            If Not Object.ReferenceEquals(socket, expectedSocket) Then Return
            If result.MessageType = WebSocketMessageType.Close Then
                Dim failure As New ConvexClient.TransportException("live", New WebSocketException("Live WebSocket closed unexpectedly"))
                DeliverFailure(failure)
                AbortSocket("TransportError", True)
                Return
            End If
            If result.MessageType <> WebSocketMessageType.Text Then
                ProtocolFailure("Live server sent a non-text message")
                Return
            End If
            If frame.Length + result.Count > MaxFrameBytes Then
                ProtocolFailure("Live frame exceeds 1 MiB")
                Return
            End If
            frame.Write(receiveBuffer, 0, result.Count)
            If Not result.EndOfMessage Then Return

            Dim message As JsonObject
            Try
                Dim json = StrictUtf8.GetString(frame.GetBuffer(), 0, CInt(frame.Length))
                frame.SetLength(0)
                message = JsonNode.Parse(json)?.AsObject()
                If message Is Nothing Then Throw New ConvexClient.ProtocolException("empty Live frame")
                Await HandleServerMessage(expectedSocket, message).ConfigureAwait(False)
            Catch ex As ConvexClient.ProtocolException
                ProtocolFailure(ex.Message)
            Catch ex As Exception
                ProtocolFailure("invalid Live message: " & ex.Message)
            End Try
        End Function

        Private Async Function HandleServerMessage(expectedSocket As ClientWebSocket, message As JsonObject) As Task
            Dim kind = RequiredString(message, "type")
            If kind = "Ping" OrElse kind = "MutationResponse" OrElse kind = "ActionResponse" Then Return
            If kind <> "Transition" Then Throw New ConvexClient.ProtocolException("unsupported Live message: " & kind)

            Dim startVersion = ValidateVersion(message("startVersion"), "startVersion")
            Dim endVersion = ValidateVersion(message("endVersion"), "endVersion")
            If Not JsonNode.DeepEquals(startVersion, version) Then Throw New ConvexClient.ProtocolException("Live transition version mismatch")
            Dim rawModifications = TryCast(message("modifications"), JsonArray)
            If rawModifications Is Nothing Then Throw New ConvexClient.ProtocolException("Live transition omitted modifications")

            ' Parse and validate the complete transition before any subscriber can observe it.
            Dim updates As New List(Of ParsedUpdate)()
            For Each raw In rawModifications
                Dim modification = TryCast(raw, JsonObject)
                If modification Is Nothing Then Throw New ConvexClient.ProtocolException("Live transition contained an invalid modification")
                Dim modificationType = RequiredString(modification, "type")
                Dim queryId = RequiredInteger(modification, "queryId")
                If modificationType = "QueryRemoved" Then Continue For
                Dim logs = ValidateLogs(modification)
                If modificationType = "QueryUpdated" Then
                    If Not modification.ContainsKey("value") Then Throw New ConvexClient.ProtocolException("QueryUpdated omitted value")
                    updates.Add(ParsedUpdate.Success(queryId, If(modification("value") Is Nothing, Nothing, modification("value").DeepClone()), logs))
                ElseIf modificationType = "QueryFailed" Then
                    Dim messageText = RequiredString(modification, "errorMessage")
                    Dim data = If(modification("errorData") Is Nothing, Nothing, modification("errorData").DeepClone())
                    updates.Add(ParsedUpdate.Failure(queryId, New ConvexClient.FunctionException("query", messageText, data, logs), logs))
                Else
                    Throw New ConvexClient.ProtocolException("unsupported Live transition modification: " & modificationType)
                End If
            Next

            If Not Object.ReferenceEquals(socket, expectedSocket) Then Return
            version = DirectCast(endVersion.DeepClone(), JsonObject)
            maxObservedTimestamp = endVersion("ts").GetValue(Of String)()
            reconnectDelayMilliseconds = 100

            For Each parsed In updates
                Dim subscription As Subscription = Nothing
                If subscriptions.TryGetValue(parsed.QueryId, subscription) Then
                    subscription.Offer(parsed.Update)
                End If
            Next
            Await Task.CompletedTask
        End Function

        Private Sub ProtocolFailure(message As String)
            Dim failure As New ConvexClient.ProtocolException(message)
            DeliverFailure(failure)
            AbortSocket("ProtocolError", True)
        End Sub

        Private Sub DeliverFailure(failure As Exception)
            For Each subscription In subscriptions.Values
                subscription.Offer(Update.Failure(failure, Array.Empty(Of String)()))
            Next
        End Sub

        Private Sub AbortSocket(reason As String, reconnect As Boolean)
            Dim previous = socket
            socket = Nothing
            connectionGeneration += 1
            frame.SetLength(0)
            querySet = 0
            version = ZeroVersion()
            If previous IsNot Nothing Then
                previous.Abort()
                previous.Dispose()
                connectionCount += 1
            End If
            lastCloseReason = reason
            If reconnect AndAlso Not closed AndAlso subscriptions.Count > 0 Then
                reconnectAt = DateTimeOffset.UtcNow.AddMilliseconds(reconnectDelayMilliseconds)
                reconnectDelayMilliseconds = Math.Min(reconnectDelayMilliseconds * 2, 15000)
            Else
                reconnectAt = Nothing
            End If
        End Sub

        Private Sub ScheduleReconnect(reason As String)
            lastCloseReason = reason
            If Not closed AndAlso subscriptions.Count > 0 Then
                reconnectAt = DateTimeOffset.UtcNow.AddMilliseconds(reconnectDelayMilliseconds)
                reconnectDelayMilliseconds = Math.Min(reconnectDelayMilliseconds * 2, 15000)
            End If
        End Sub

        Private Function Add(subscription As Subscription) As JsonObject
            Return New JsonObject From {
                {"type", "Add"}, {"queryId", subscription.QueryId}, {"udfPath", subscription.Path},
                {"args", New JsonArray(subscription.Args.DeepClone())}
            }
        End Function

        Private Shared Function Remove(queryId As Integer) As JsonObject
            Return New JsonObject From {{"type", "Remove"}, {"queryId", queryId}}
        End Function

        Private Async Function Modify(modifications As IEnumerable(Of JsonObject)) As Task
            Dim entries As New JsonArray()
            For Each modification In modifications
                entries.Add(modification)
            Next
            Await Send(New JsonObject From {
                {"type", "ModifyQuerySet"}, {"baseVersion", querySet},
                {"newVersion", querySet + 1}, {"modifications", entries}
            }).ConfigureAwait(False)
            querySet += 1
        End Function

        Private Async Function Send(message As JsonObject) As Task
            Dim target = socket
            If target Is Nothing Then Throw New InvalidOperationException("Live WebSocket is not connected")
            Dim bytes = Encoding.UTF8.GetBytes(message.ToJsonString())
            Using bounded = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                bounded.CancelAfter(TimeSpan.FromSeconds(3))
                Await target.SendAsync(bytes, WebSocketMessageType.Text, True, bounded.Token).ConfigureAwait(False)
            End Using
        End Function

        Private Shared Function ValidateVersion(node As JsonNode, name As String) As JsonObject
            Dim result = TryCast(node, JsonObject)
            If result Is Nothing Then Throw New ConvexClient.ProtocolException("Live transition omitted " & name)
            RequiredNonnegativeInteger(result, "querySet")
            RequiredNonnegativeInteger(result, "identity")
            Dim timestamp = RequiredString(result, "ts")
            Try
                Dim decoded = Convert.FromBase64String(timestamp)
                If decoded.Length <> 8 Then Throw New FormatException("timestamp must contain eight bytes")
            Catch ex As Exception
                Throw New ConvexClient.ProtocolException(name & " has an invalid timestamp")
            End Try
            If result.Count <> 3 Then Throw New ConvexClient.ProtocolException(name & " contains unknown fields")
            Return result
        End Function

        Private Shared Function ValidateLogs(message As JsonObject) As IReadOnlyList(Of String)
            If Not message.ContainsKey("logLines") Then Return Array.Empty(Of String)()
            Dim raw = TryCast(message("logLines"), JsonArray)
            If raw Is Nothing Then Throw New ConvexClient.ProtocolException("logLines must be an array")
            Dim result As New List(Of String)(raw.Count)
            For Each line In raw
                If line Is Nothing Then Throw New ConvexClient.ProtocolException("logLines must contain strings")
                Try
                    result.Add(line.GetValue(Of String)())
                Catch ex As Exception
                    Throw New ConvexClient.ProtocolException("logLines must contain strings")
                End Try
            Next
            Return result
        End Function

        Private Shared Function RequiredString(value As JsonObject, name As String) As String
            If Not value.ContainsKey(name) OrElse value(name) Is Nothing Then Throw New ConvexClient.ProtocolException(name & " is required")
            Try
                Dim result = value(name).GetValue(Of String)()
                If String.IsNullOrEmpty(result) Then Throw New ConvexClient.ProtocolException(name & " is required")
                Return result
            Catch ex As ConvexClient.ProtocolException
                Throw
            Catch ex As Exception
                Throw New ConvexClient.ProtocolException(name & " must be a string")
            End Try
        End Function

        Private Shared Function RequiredInteger(value As JsonObject, name As String) As Integer
            If Not value.ContainsKey(name) OrElse value(name) Is Nothing Then Throw New ConvexClient.ProtocolException(name & " is required")
            Try
                Return value(name).GetValue(Of Integer)()
            Catch ex As Exception
                Throw New ConvexClient.ProtocolException(name & " must be an integer")
            End Try
        End Function

        Private Shared Function RequiredNonnegativeInteger(value As JsonObject, name As String) As Integer
            Dim result = RequiredInteger(value, name)
            If result < 0 Then Throw New ConvexClient.ProtocolException(name & " must be nonnegative")
            Return result
        End Function

        Private Shared Function ZeroVersion() As JsonObject
            Return New JsonObject From {{"querySet", 0}, {"identity", 0}, {"ts", "AAAAAAAAAAA="}}
        End Function

        Public Sub Dispose() Implements IDisposable.Dispose
            If closed Then Return
            Try
                CloseAsync().WaitAsync(TimeSpan.FromSeconds(4)).GetAwaiter().GetResult()
            Catch ex As ObjectDisposedException
            End Try
        End Sub

        Public NotInheritable Class Update
            Private Sub New(hasValue As Boolean, value As JsonNode, failure As Exception, logs As IReadOnlyList(Of String))
                Me.HasValue = hasValue
                Me.Value = value
                [Error] = failure
                Me.Logs = logs
                EncodedBytes = Measure(hasValue, value, failure, logs)
            End Sub

            Public ReadOnly Property HasValue As Boolean
            Public ReadOnly Property Value As JsonNode
            Public ReadOnly Property [Error] As Exception
            Public ReadOnly Property Logs As IReadOnlyList(Of String)
            Friend ReadOnly Property EncodedBytes As Integer

            Public Shared Function Success(value As JsonNode, logs As IReadOnlyList(Of String)) As Update
                Return New Update(True, value, Nothing, logs)
            End Function

            Public Shared Function Failure(errorValue As Exception, logs As IReadOnlyList(Of String)) As Update
                Return New Update(False, Nothing, errorValue, logs)
            End Function

            Private Shared Function Measure(hasValue As Boolean, value As JsonNode, failure As Exception, logs As IReadOnlyList(Of String)) As Integer
                Dim envelope As New JsonObject From {{"type", "subscription"}, {"subscriptionId", New String("s"c, 128)}}
                If hasValue Then
                    envelope("value") = If(value Is Nothing, Nothing, value.DeepClone())
                    Dim logArray As New JsonArray()
                    For Each line In logs
                        logArray.Add(line)
                    Next
                    envelope("logs") = logArray
                Else
                    envelope("error") = New JsonObject From {
                        {"name", CanonicalErrorName(failure)}, {"message", failure.Message},
                        {"data", TryCast(failure, ConvexClient.FunctionException)?.ErrorData?.DeepClone()}
                    }
                End If
                Return Encoding.UTF8.GetByteCount(envelope.ToJsonString()) + 256
            End Function

            Friend Shared Function CanonicalErrorName(failure As Exception) As String
                If TypeOf failure Is ConvexClient.FunctionException Then Return "FunctionError"
                If TypeOf failure Is ConvexClient.ProtocolException Then Return "ProtocolError"
                If TypeOf failure Is ConvexClient.TransportException Then Return "TransportError"
                Return "Error"
            End Function
        End Class

        Public NotInheritable Class Subscription
            Implements IDisposable
            Private Const MaxUpdates As Integer = 16
            Private Const MaxEncodedBytes As Integer = 1048576
            Private ReadOnly owner As LiveClient
            Private ReadOnly deliveryGate As New Object()
            Private ReadOnly updates As New Queue(Of Update)()
            Private queuedBytes As Integer
            Private closed As Boolean
            Private hydrating As Boolean
            Private lastSuccessfulFingerprint As String

            Friend Sub New(client As LiveClient, id As Integer, functionPath As String, functionArgs As JsonObject)
                owner = client
                QueryId = id
                Path = functionPath
                Args = functionArgs
            End Sub

            Friend ReadOnly Property QueryId As Integer
            Friend ReadOnly Property Path As String
            Friend ReadOnly Property Args As JsonObject

            Friend Sub BeginHydration()
                SyncLock deliveryGate
                    hydrating = True
                End SyncLock
            End Sub

            Friend Sub Offer(update As Update)
                SyncLock deliveryGate
                    If closed Then Return
                    If update.HasValue Then
                        Dim fingerprint = If(update.Value Is Nothing, "null", update.Value.ToJsonString())
                        If hydrating AndAlso lastSuccessfulFingerprint IsNot Nothing AndAlso fingerprint = lastSuccessfulFingerprint Then
                            hydrating = False
                            Return
                        End If
                        hydrating = False
                        lastSuccessfulFingerprint = fingerprint
                    Else
                        hydrating = False
                    End If

                    If update.EncodedBytes > MaxEncodedBytes Then
                        updates.Clear()
                        queuedBytes = 0
                        updates.Enqueue(Update.Failure(New ConvexClient.ProtocolException("Live update exceeds the 1 MiB delivery budget"), Array.Empty(Of String)()))
                        queuedBytes = updates.Peek().EncodedBytes
                    Else
                        While updates.Count >= MaxUpdates OrElse queuedBytes + update.EncodedBytes > MaxEncodedBytes
                            queuedBytes -= updates.Dequeue().EncodedBytes
                        End While
                        updates.Enqueue(update)
                        queuedBytes += update.EncodedBytes
                    End If
                    Monitor.PulseAll(deliveryGate)
                End SyncLock
            End Sub

            Friend Sub Finish()
                SyncLock deliveryGate
                    If closed Then Return
                    closed = True
                    Monitor.PulseAll(deliveryGate)
                End SyncLock
            End Sub

            Public Function NextUpdate(timeout As TimeSpan) As Update
                Dim deadline = DateTime.UtcNow + timeout
                SyncLock deliveryGate
                    While updates.Count = 0 AndAlso Not closed
                        Dim remaining = CInt(Math.Max(0, (deadline - DateTime.UtcNow).TotalMilliseconds))
                        If remaining = 0 OrElse Not Monitor.Wait(deliveryGate, remaining) Then Throw New TimeoutException("timed out waiting for Live update")
                    End While
                    If updates.Count = 0 Then Throw New InvalidOperationException("Live subscription is closed")
                    Dim result = updates.Dequeue()
                    queuedBytes -= result.EncodedBytes
                    Return result
                End SyncLock
            End Function

            Public Function [Next](timeout As TimeSpan) As JsonNode
                Dim update = NextUpdate(timeout)
                If update.Error IsNot Nothing Then Throw update.Error
                Return update.Value
            End Function

            Public Sub Dispose() Implements IDisposable.Dispose
                If owner Is Nothing Then
                    Finish()
                    Return
                End If
                Try
                    owner.Unsubscribe(Me).WaitAsync(TimeSpan.FromSeconds(3)).GetAwaiter().GetResult()
                Catch ex As ObjectDisposedException
                    ' Closing the owner already invalidated every subscription.
                    Finish()
                End Try
            End Sub
        End Class

        Private MustInherit Class OwnerCommand
            Public MustOverride Sub Fail(failure As Exception)
        End Class

        Private NotInheritable Class SubscribeCommand
            Inherits OwnerCommand
            Public Sub New(path As String, args As JsonObject, completion As TaskCompletionSource(Of Subscription))
                Me.Path = path
                Me.Args = args
                Me.Completion = completion
            End Sub
            Public ReadOnly Property Path As String
            Public ReadOnly Property Args As JsonObject
            Public ReadOnly Property Completion As TaskCompletionSource(Of Subscription)
            Public Overrides Sub Fail(failure As Exception)
                Completion.TrySetException(failure)
            End Sub
        End Class

        Private NotInheritable Class UnsubscribeCommand
            Inherits OwnerCommand
            Public Sub New(subscription As Subscription, completion As TaskCompletionSource(Of Boolean))
                Me.Subscription = subscription
                Me.Completion = completion
            End Sub
            Public ReadOnly Property Subscription As Subscription
            Public ReadOnly Property Completion As TaskCompletionSource(Of Boolean)
            Public Overrides Sub Fail(failure As Exception)
                Completion.TrySetException(failure)
            End Sub
        End Class

        Private NotInheritable Class DebugDisconnectCommand
            Inherits OwnerCommand
            Public Sub New(completion As TaskCompletionSource(Of Boolean))
                Me.Completion = completion
            End Sub
            Public ReadOnly Property Completion As TaskCompletionSource(Of Boolean)
            Public Overrides Sub Fail(failure As Exception)
                Completion.TrySetException(failure)
            End Sub
        End Class

        Private NotInheritable Class CloseCommand
            Inherits OwnerCommand
            Public Sub New(completion As TaskCompletionSource(Of Boolean))
                Me.Completion = completion
            End Sub
            Public ReadOnly Property Completion As TaskCompletionSource(Of Boolean)
            Public Overrides Sub Fail(failure As Exception)
                Completion.TrySetException(failure)
            End Sub
        End Class

        Private NotInheritable Class ParsedUpdate
            Private Sub New(queryId As Integer, update As Update)
                Me.QueryId = queryId
                Me.Update = update
            End Sub
            Public ReadOnly Property QueryId As Integer
            Public ReadOnly Property Update As Update
            Public Shared Function Success(queryId As Integer, value As JsonNode, logs As IReadOnlyList(Of String)) As ParsedUpdate
                Return New ParsedUpdate(queryId, LiveClient.Update.Success(value, logs))
            End Function
            Public Shared Function Failure(queryId As Integer, errorValue As Exception, logs As IReadOnlyList(Of String)) As ParsedUpdate
                Return New ParsedUpdate(queryId, LiveClient.Update.Failure(errorValue, logs))
            End Function
        End Class
    End Class
End Namespace
