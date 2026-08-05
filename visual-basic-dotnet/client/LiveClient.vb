Imports System.Collections.Concurrent
Imports System.IO
Imports System.Net.WebSockets
Imports System.Text
Imports System.Text.Json.Nodes
Imports System.Threading

Namespace ConvexVisualBasic
    ''' <summary>
    ''' Native owner-loop implementation of Convex's pinned experimental /api/sync profile.
    ''' WebSocket reads, writes, reconnects and query-set versions are serialized by ownerGate.
    ''' </summary>
    Public NotInheritable Class LiveClient
        Implements IDisposable

        Private ReadOnly endpoint As Uri
        Private ReadOnly subscriptions As New ConcurrentDictionary(Of Integer, Subscription)()
        Private ReadOnly ownerGate As New SemaphoreSlim(1, 1)
        Private ReadOnly lifetime As New CancellationTokenSource()
        Private socket As ClientWebSocket
        Private receiveTask As Task
        Private nextId As Integer
        Private querySet As Integer
        Private connections As Integer
        Private isClosed As Boolean
        Private reconnecting As Boolean
        Private intentionalRecovery As Boolean
        Private lastClose As String = "InitialConnect"
        Private maxObservedTimestamp As String
        Private version As JsonObject = ZeroVersion()
        Private Shared ReadOnly strictUtf8 As New UTF8Encoding(False, True)

        Public Sub New(deployment As String)
            Dim baseUri As New Uri(deployment.TrimEnd("/"c))
            Dim builder As New UriBuilder(baseUri) With {
                .Scheme = If(baseUri.Scheme = Uri.UriSchemeHttps, "wss", "ws"),
                .Path = baseUri.AbsolutePath.TrimEnd("/"c) & "/api/sync"
            }
            endpoint = builder.Uri
        End Sub

        Public Async Function Subscribe(path As String, args As JsonObject) As Task(Of Subscription)
            If String.IsNullOrWhiteSpace(path) Then Throw New ArgumentException("Convex function path is required")
            Await ownerGate.WaitAsync().ConfigureAwait(False)
            Try
                ThrowIfClosed()
                Dim subscription = New Subscription(Me, nextId, path, DirectCast(args.DeepClone(), JsonObject))
                nextId += 1
                If Not subscriptions.TryAdd(subscription.QueryId, subscription) Then Throw New InvalidOperationException("duplicate Live query id")
                Try
                    If socket Is Nothing Then
                        Await ConnectOwned().ConfigureAwait(False)
                    Else
                        Await ModifyOwned({Add(subscription)}).ConfigureAwait(False)
                    End If
                    Return subscription
                Catch
                    Dim ignored As Subscription = Nothing
                    subscriptions.TryRemove(subscription.QueryId, ignored)
                    Throw
                End Try
            Finally
                ownerGate.Release()
            End Try
        End Function

        Private Async Function ConnectOwned() As Task
            ThrowIfClosed()
            Dim connected As New ClientWebSocket()
            connected.Options.SetRequestHeader("Convex-Client", "visual-basic-dotnet-0.1.0")
            Await connected.ConnectAsync(endpoint, lifetime.Token).ConfigureAwait(False)
            socket = connected
            querySet = 0
            version = ZeroVersion()
            receiveTask = Receive(connected)
            Dim connect As New JsonObject From {
                {"type", "Connect"}, {"sessionId", Guid.NewGuid().ToString()},
                {"connectionCount", connections}, {"lastCloseReason", lastClose}, {"clientTs", 0}
            }
            If maxObservedTimestamp IsNot Nothing Then connect("maxObservedTimestamp") = maxObservedTimestamp
            Await SendOwned(connect).ConfigureAwait(False)
            If Not subscriptions.IsEmpty Then Await ModifyOwned(subscriptions.Values.Select(Function(value) Add(value))).ConfigureAwait(False)
        End Function

        Private Function Add(subscription As Subscription) As JsonObject
            Return New JsonObject From {
                {"type", "Add"}, {"queryId", subscription.QueryId}, {"udfPath", subscription.Path},
                {"args", New JsonArray(subscription.Args.DeepClone())}
            }
        End Function

        Private Async Function ModifyOwned(modifications As IEnumerable(Of JsonObject)) As Task
            Dim entries As New JsonArray()
            For Each modification In modifications
                entries.Add(modification)
            Next
            Await SendOwned(New JsonObject From {
                {"type", "ModifyQuerySet"}, {"baseVersion", querySet}, {"newVersion", querySet + 1}, {"modifications", entries}
            }).ConfigureAwait(False)
            querySet += 1
        End Function

        Private Async Function SendOwned(message As JsonObject) As Task
            Dim target = socket
            If target Is Nothing Then Throw New InvalidOperationException("Live WebSocket is not connected")
            Using bounded = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                bounded.CancelAfter(TimeSpan.FromSeconds(3))
                Dim bytes = Encoding.UTF8.GetBytes(message.ToJsonString())
                Await target.SendAsync(bytes, WebSocketMessageType.Text, True, bounded.Token).ConfigureAwait(False)
            End Using
        End Function

        Private Async Function Receive(expected As ClientWebSocket) As Task
            Dim buffer(4095) As Byte
            Using frame As New MemoryStream()
                Dim failure As Exception = Nothing
                Try
                    While Not isClosed AndAlso expected.State = WebSocketState.Open
                        Dim result = Await expected.ReceiveAsync(buffer, lifetime.Token).ConfigureAwait(False)
                        If result.MessageType = WebSocketMessageType.Close Then
                            failure = New ConvexClient.TransportException("live", New WebSocketException("Live WebSocket closed unexpectedly"))
                            Exit While
                        End If
                        If result.MessageType <> WebSocketMessageType.Text Then Throw New ConvexClient.ProtocolException("Live server sent a non-text frame")
                        frame.Write(buffer, 0, result.Count)
                        If Not result.EndOfMessage Then Continue While
                        Dim json = strictUtf8.GetString(frame.GetBuffer(), 0, CInt(frame.Length))
                        frame.SetLength(0)
                        Dim parsed = JsonNode.Parse(json)?.AsObject()
                        If parsed Is Nothing Then Throw New ConvexClient.ProtocolException("empty Live frame")
                        Await HandleTransition(expected, parsed).ConfigureAwait(False)
                    End While
                Catch ex As OperationCanceledException When isClosed
                    Return
                Catch ex As ConvexClient.ProtocolException
                    failure = ex
                Catch ex As Exception
                    failure = New ConvexClient.TransportException("live", ex)
                End Try
                Await DisconnectOwned(expected, If(TypeOf failure Is ConvexClient.ProtocolException, "ProtocolError", "TransportError"), True, failure).ConfigureAwait(False)
            End Using
        End Function

        Private Async Function HandleTransition(expected As ClientWebSocket, message As JsonObject) As Task
            Dim kind = message("type")?.GetValue(Of String)()
            If kind = "Ping" OrElse kind = "MutationResponse" OrElse kind = "ActionResponse" Then Return
            If kind <> "Transition" Then Throw New ConvexClient.ProtocolException("unsupported Live message: " & kind)
            Dim startVersion = message("startVersion")?.AsObject()
            Dim endVersion = message("endVersion")?.AsObject()
            If startVersion Is Nothing OrElse endVersion Is Nothing Then Throw New ConvexClient.ProtocolException("Live transition omitted a version")
            Dim updates As New List(Of (QueryId As Integer, Update As Update))()
            For Each item In If(message("modifications")?.AsArray(), New JsonArray())
                Dim modification = item?.AsObject()
                If modification Is Nothing Then Throw New ConvexClient.ProtocolException("Live transition contained an invalid modification")
                Dim modificationType = modification("type")?.GetValue(Of String)()
                If modificationType = "QueryRemoved" Then Continue For
                Dim id = modification("queryId")?.GetValue(Of Integer)()
                If Not id.HasValue Then Throw New ConvexClient.ProtocolException("Live modification omitted queryId")
                Dim logs = ConvexClient.DecodeLogs(modification)
                If modificationType = "QueryUpdated" Then
                    If Not modification.ContainsKey("value") Then Throw New ConvexClient.ProtocolException("QueryUpdated omitted value")
                    updates.Add((id.Value, New Update(If(modification("value") Is Nothing, Nothing, modification("value").DeepClone()), Nothing, logs)))
                ElseIf modificationType = "QueryFailed" Then
                    updates.Add((id.Value, New Update(Nothing, New ConvexClient.FunctionException("query", If(modification("errorMessage")?.GetValue(Of String)(), "query failed"), modification("errorData"), logs), logs)))
                Else
                    Throw New ConvexClient.ProtocolException("unsupported Live transition modification: " & modificationType)
                End If
            Next

            ' A dead socket cannot publish a queued transition after an unsubscribe or replacement acknowledgement.
            Await ownerGate.WaitAsync().ConfigureAwait(False)
            Try
                If Not Object.ReferenceEquals(socket, expected) Then Return
                If Not JsonNode.DeepEquals(startVersion, version) Then Throw New ConvexClient.ProtocolException("Live transition version mismatch")
                Dim restored = False
                For Each update In updates
                    Dim subscription As Subscription = Nothing
                    If subscriptions.TryGetValue(update.QueryId, subscription) Then
                        subscription.Offer(update.Update)
                        restored = True
                    End If
                Next
                version = DirectCast(endVersion.DeepClone(), JsonObject)
                maxObservedTimestamp = version("ts")?.GetValue(Of String)()
                If restored Then intentionalRecovery = False
            Finally
                ownerGate.Release()
            End Try
        End Function

        Private Async Function DisconnectOwned(expected As ClientWebSocket, reason As String, shouldReconnect As Boolean, failure As Exception) As Task
            Await ownerGate.WaitAsync().ConfigureAwait(False)
            Try
                If expected IsNot Nothing AndAlso Not Object.ReferenceEquals(socket, expected) Then Return
                If failure IsNot Nothing AndAlso Not intentionalRecovery Then
                    For Each subscription In subscriptions.Values
                        subscription.Offer(New Update(Nothing, failure, Array.Empty(Of String)()))
                    Next
                End If
                If socket IsNot Nothing Then
                    socket.Abort()
                    socket.Dispose()
                    socket = Nothing
                    connections += 1
                End If
                lastClose = reason
                querySet = 0
                version = ZeroVersion()
                If shouldReconnect AndAlso Not subscriptions.IsEmpty AndAlso Not isClosed AndAlso Not reconnecting Then
                    reconnecting = True
                    Dim ignored = Reconnect()
                End If
            Finally
                ownerGate.Release()
            End Try
        End Function

        Private Async Function Reconnect() As Task
            Dim delay As Integer = 100
            While Not isClosed
                Try
                    Await Task.Delay(delay, lifetime.Token).ConfigureAwait(False)
                    Await ownerGate.WaitAsync(lifetime.Token).ConfigureAwait(False)
                    Try
                        If socket Is Nothing Then Await ConnectOwned().ConfigureAwait(False)
                        reconnecting = False
                        Return
                    Finally
                        ownerGate.Release()
                    End Try
                Catch ex As OperationCanceledException
                    Return
                Catch ex As Exception
                    delay = Math.Min(delay * 2, 15000)
                End Try
            End While
        End Function

        Public Async Function DebugDisconnect() As Task
            Dim stopped As Task = Nothing
            Await ownerGate.WaitAsync().ConfigureAwait(False)
            Try
                ThrowIfClosed()
                If socket Is Nothing Then Throw New InvalidOperationException("Live WebSocket is not connected")
                Dim previous = socket
                socket = Nothing
                stopped = receiveTask
                receiveTask = Nothing
                previous.Abort()
                previous.Dispose()
                connections += 1
                lastClose = "DebugDisconnect"
                querySet = 0
                version = ZeroVersion()
                intentionalRecovery = True
            Finally
                ownerGate.Release()
            End Try
            If stopped IsNot Nothing Then Await stopped.WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(False)
            Await ownerGate.WaitAsync().ConfigureAwait(False)
            Try
                If Not isClosed AndAlso Not subscriptions.IsEmpty AndAlso socket Is Nothing AndAlso Not reconnecting Then
                    reconnecting = True
                    Dim ignored = Reconnect()
                End If
            Finally
                ownerGate.Release()
            End Try
        End Function

        Friend Async Function Unsubscribe(subscription As Subscription) As Task
            Await ownerGate.WaitAsync().ConfigureAwait(False)
            Try
                Dim ignored As Subscription = Nothing
                If subscriptions.TryRemove(subscription.QueryId, ignored) Then
                    subscription.Finish()
                    If socket IsNot Nothing Then Await ModifyOwned({New JsonObject From {{"type", "Remove"}, {"queryId", subscription.QueryId}}}).ConfigureAwait(False)
                End If
            Finally
                ownerGate.Release()
            End Try
        End Function

        Private Shared Function ZeroVersion() As JsonObject
            Return New JsonObject From {{"querySet", 0}, {"identity", 0}, {"ts", "AAAAAAAAAAA="}}
        End Function

        Private Sub ThrowIfClosed()
            If isClosed Then Throw New ObjectDisposedException(NameOf(LiveClient))
        End Sub

        Public Sub Dispose() Implements IDisposable.Dispose
            If isClosed Then Return
            isClosed = True
            intentionalRecovery = False
            lifetime.Cancel()
            Dim previous = socket
            socket = Nothing
            receiveTask = Nothing
            If previous IsNot Nothing Then
                previous.Abort()
                previous.Dispose()
            End If
            For Each subscription In subscriptions.Values
                subscription.Finish()
            Next
            subscriptions.Clear()
        End Sub

        Public NotInheritable Class Update
            Public Sub New(value As JsonNode, failure As Exception, logs As IReadOnlyList(Of String))
                Me.Value = value
                [Error] = failure
                Me.Logs = logs
            End Sub
            Public ReadOnly Property Value As JsonNode
            Public ReadOnly Property [Error] As Exception
            Public ReadOnly Property Logs As IReadOnlyList(Of String)
        End Class

        Public NotInheritable Class Subscription
            Implements IDisposable
            Private ReadOnly owner As LiveClient
            Private ReadOnly deliveryGate As New Object()
            Private ReadOnly updates As New Queue(Of Update)()
            Private queuedBytes As Integer
            Private closed As Boolean
            Private Const MaxUpdates As Integer = 16
            Private Const MaxEncodedBytes As Integer = 1048576

            Friend Sub New(client As LiveClient, id As Integer, functionPath As String, functionArgs As JsonObject)
                owner = client
                QueryId = id
                Path = functionPath
                Args = functionArgs
            End Sub
            Friend ReadOnly Property QueryId As Integer
            Friend ReadOnly Property Path As String
            Friend ReadOnly Property Args As JsonObject

            Friend Sub Offer(update As Update)
                Dim size = Math.Max(64, Encoding.UTF8.GetByteCount(If(update.Value Is Nothing, update.Error?.Message, update.Value.ToJsonString())))
                SyncLock deliveryGate
                    If closed Then Return
                    While updates.Count >= MaxUpdates OrElse (updates.Count > 0 AndAlso queuedBytes + size > MaxEncodedBytes)
                        queuedBytes -= EncodedSize(updates.Dequeue())
                    End While
                    If size > MaxEncodedBytes Then Return
                    updates.Enqueue(update)
                    queuedBytes += size
                    Threading.Monitor.PulseAll(deliveryGate)
                End SyncLock
            End Sub

            Private Shared Function EncodedSize(update As Update) As Integer
                Return Math.Max(64, Encoding.UTF8.GetByteCount(If(update.Value Is Nothing, update.Error?.Message, update.Value.ToJsonString())))
            End Function

            Friend Sub Finish()
                SyncLock deliveryGate
                    closed = True
                    Threading.Monitor.PulseAll(deliveryGate)
                End SyncLock
            End Sub

            Public Function NextUpdate(timeout As TimeSpan) As Update
                Dim deadline = Date.UtcNow + timeout
                SyncLock deliveryGate
                    While updates.Count = 0 AndAlso Not closed
                        Dim remaining = CInt(Math.Max(0, (deadline - Date.UtcNow).TotalMilliseconds))
                        If remaining = 0 OrElse Not Threading.Monitor.Wait(deliveryGate, remaining) Then Throw New TimeoutException("timed out waiting for Live update")
                    End While
                    If updates.Count = 0 Then Throw New InvalidOperationException("Live subscription is closed")
                    Dim update = updates.Dequeue()
                    queuedBytes -= EncodedSize(update)
                    Return update
                End SyncLock
            End Function

            Public Function [Next](timeout As TimeSpan) As JsonNode
                Dim update = NextUpdate(timeout)
                If update.Error IsNot Nothing Then Throw update.Error
                Return update.Value
            End Function

            Public Sub Dispose() Implements IDisposable.Dispose
                owner.Unsubscribe(Me).GetAwaiter().GetResult()
            End Sub
        End Class
    End Class
End Namespace
