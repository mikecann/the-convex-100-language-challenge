Imports System.Collections.Concurrent
Imports System.IO
Imports System.Net
Imports System.Net.Sockets
Imports System.Text.Json
Imports System.Text.Json.Nodes
Imports System.Threading
Imports ConvexVisualBasic

''' <summary>Test-only NDJSON v1 adapter. It always invokes the native Visual Basic client.</summary>
Module Program
    Private Const MaxCommandBytes As Integer = 1048576
    Private ReadOnly serializer As New JsonSerializerOptions With {.DefaultIgnoreCondition = Serialization.JsonIgnoreCondition.WhenWritingNull}

    Public Sub Main(args As String())
        MainAsync().GetAwaiter().GetResult()
    End Sub

    Private Async Function MainAsync() As Task
        Dim listen = Environment.GetEnvironmentVariable("ADAPTER_LISTEN")
        If String.IsNullOrWhiteSpace(listen) Then
            Await Run(Console.In, Console.Out, Environment.GetEnvironmentVariable("CONVEX_URL"))
            Return
        End If
        Dim parts = listen.Split(":"c)
        If parts.Length <> 2 Then Throw New InvalidOperationException("ADAPTER_LISTEN must be host:port")
        Dim server As New TcpListener(IPAddress.Parse(parts(0)), Integer.Parse(parts(1)))
        server.Start()
        Using accepted = Await server.AcceptTcpClientAsync()
        Using stream = accepted.GetStream()
        Using input As New StreamReader(stream)
        Using output As New StreamWriter(stream) With {.AutoFlush = True}
            Await Run(input, output, Environment.GetEnvironmentVariable("CONVEX_URL"))
        End Using
        End Using
        End Using
        End Using
    End Function

    Friend Async Function Run(input As TextReader, output As TextWriter, url As String) As Task
        Dim writer As New LockedWriter(output)
        Dim subscriptions As New ConcurrentDictionary(Of String, LiveClient.Subscription)()
        Dim relays As New ConcurrentDictionary(Of String, CancellationTokenSource)()
        Dim client As ConvexClient = Nothing
        Dim live As LiveClient = Nothing
        Try
            While True
                Dim line = Await ReadBoundedLine(input)
                If line Is Nothing Then Exit While
                Dim command As JsonObject = Nothing
                Dim parseFailure As Exception = Nothing
                Try
                    command = JsonNode.Parse(line)?.AsObject()
                    If command Is Nothing Then Throw New InvalidOperationException("command is not an object")
                Catch ex As Exception
                    parseFailure = ex
                End Try
                If parseFailure IsNot Nothing Then
                    Await writer.WriteAsync(Failure(Nothing, parseFailure))
                    Continue While
                End If
                Dim id = command("id")?.GetValue(Of String)()
                Dim commandFailure As Exception = Nothing
                Try
                    Dim op = command("op")?.GetValue(Of String)()
                    Select Case op
                        Case "hello"
                            If command("protocolVersion")?.GetValue(Of Integer)() <> 1 Then Throw New InvalidOperationException("unsupported protocol version")
                            Await writer.WriteAsync(New JsonObject From {
                                {"protocolVersion", 1}, {"id", id}, {"type", "ready"}, {"language", "visual-basic-dotnet"},
                                {"implementation", "native-visual-basic-dotnet-0.1.0"}, {"runtime", Environment.Version.ToString()}
                            })
                        Case "query", "mutation", "action"
                            If client Is Nothing Then client = New ConvexClient(RequiredUrl(url))
                            Dim value As JsonObject = command("args")?.AsObject()
                            If value Is Nothing Then Throw New InvalidOperationException("args must be an object")
                            Dim result As ConvexClient.Result
                            If op = "query" Then
                                result = Await client.Query(command("path")?.GetValue(Of String)(), value)
                            ElseIf op = "mutation" Then
                                result = Await client.Mutation(command("path")?.GetValue(Of String)(), value)
                            Else
                                result = Await client.Action(command("path")?.GetValue(Of String)(), value)
                            End If
                            Await writer.WriteAsync(New JsonObject From {{"id", id}, {"type", "result"}, {"value", result.Value}, {"logs", LogArray(result.Logs)}})
                        Case "setAuth"
                            If client Is Nothing Then client = New ConvexClient(RequiredUrl(url))
                            client.SetAuth(command("token")?.GetValue(Of String)())
                            Await writer.WriteAsync(New JsonObject From {{"id", id}, {"type", "ack"}})
                        Case "subscribe"
                            If live Is Nothing Then live = New LiveClient(RequiredUrl(url))
                            Dim subscriptionId = RequiredString(command, "subscriptionId")
                            Dim previous As LiveClient.Subscription = Nothing
                            If subscriptions.TryRemove(subscriptionId, previous) Then previous.Dispose()
                            Dim previousRelay As CancellationTokenSource = Nothing
                            If relays.TryRemove(subscriptionId, previousRelay) Then previousRelay.Cancel()
                            Dim args = command("args")?.AsObject()
                            If args Is Nothing Then Throw New InvalidOperationException("args must be an object")
                            Dim subscription = Await live.Subscribe(RequiredString(command, "path"), args)
                            If Not subscriptions.TryAdd(subscriptionId, subscription) Then Throw New InvalidOperationException("subscription replacement failed")
                            Await writer.WriteAsync(New JsonObject From {{"id", id}, {"type", "ack"}})
                            Dim cancellation As New CancellationTokenSource()
                            relays(subscriptionId) = cancellation
                            Dim ignored = Relay(subscriptionId, subscription, cancellation.Token, subscriptions, writer)
                        Case "unsubscribe"
                            Dim subscriptionId = RequiredString(command, "subscriptionId")
                            Dim previous As LiveClient.Subscription = Nothing
                            If subscriptions.TryRemove(subscriptionId, previous) Then previous.Dispose()
                            Dim cancellation As CancellationTokenSource = Nothing
                            If relays.TryRemove(subscriptionId, cancellation) Then cancellation.Cancel()
                            Await writer.WriteAsync(New JsonObject From {{"id", id}, {"type", "ack"}})
                        Case "debugDisconnect"
                            If live Is Nothing Then Throw New InvalidOperationException("no active Live connection")
                            ' Debug acknowledgement is delayed until the old socket has retired and reconnect work is scheduled.
                            Await live.DebugDisconnect()
                            Await writer.WriteAsync(New JsonObject From {{"id", id}, {"type", "ack"}})
                        Case "close"
                            For Each cancellation In relays.Values
                                cancellation.Cancel()
                            Next
                            For Each subscription In subscriptions.Values
                                subscription.Dispose()
                            Next
                            live?.Dispose()
                            client?.Dispose()
                            Await writer.WriteAsync(New JsonObject From {{"id", id}, {"type", "closed"}})
                            Return
                        Case Else
                            Throw New InvalidOperationException("unknown operation: " & op)
                    End Select
                Catch ex As Exception
                    commandFailure = ex
                End Try
                If commandFailure IsNot Nothing Then Await writer.WriteAsync(Failure(id, commandFailure))
            End While
        Finally
            For Each cancellation In relays.Values
                cancellation.Cancel()
            Next
            For Each subscription In subscriptions.Values
                subscription.Dispose()
            Next
            live?.Dispose()
            client?.Dispose()
        End Try
    End Function

    Private Async Function Relay(subscriptionId As String, subscription As LiveClient.Subscription, cancellation As CancellationToken, subscriptions As ConcurrentDictionary(Of String, LiveClient.Subscription), writer As LockedWriter) As Task
        While Not cancellation.IsCancellationRequested
            Dim relayFailure As Exception = Nothing
            Try
                Dim update = Await Task.Run(Function() subscription.NextUpdate(TimeSpan.FromMilliseconds(250)), cancellation)
                Dim current As LiveClient.Subscription = Nothing
                ' This identity barrier suppresses a dequeued old relay after unsubscribe or same-ID replacement.
                If Not subscriptions.TryGetValue(subscriptionId, current) OrElse Not Object.ReferenceEquals(current, subscription) Then Return
                If update.Error Is Nothing Then
                    Await writer.WriteAsync(New JsonObject From {{"type", "subscription"}, {"subscriptionId", subscriptionId}, {"value", update.Value}, {"logs", LogArray(update.Logs)}})
                Else
                    Await writer.WriteAsync(New JsonObject From {{"type", "subscription"}, {"subscriptionId", subscriptionId}, {"error", ErrorObject(update.Error)}})
                End If
            Catch ex As TimeoutException
                ' Periodic timeout permits prompt cancellation without a second reader touching the socket.
            Catch ex As OperationCanceledException
                Return
            Catch ex As Exception
                relayFailure = ex
            End Try
            If relayFailure IsNot Nothing Then
                If Not cancellation.IsCancellationRequested Then Await writer.WriteAsync(New JsonObject From {{"type", "subscription"}, {"subscriptionId", subscriptionId}, {"error", ErrorObject(relayFailure)}})
                Return
            End If
        End While
    End Function

    Private Function Failure(id As String, ex As Exception) As JsonObject
        Dim response As New JsonObject From {{"type", "error"}, {"error", ErrorObject(ex)}}
        If Not String.IsNullOrEmpty(id) Then response("id") = id
        Return response
    End Function

    Private Function ErrorObject(ex As Exception) As JsonObject
        Dim data As JsonNode = Nothing
        Dim functionError = TryCast(ex, ConvexClient.FunctionException)
        If functionError IsNot Nothing Then data = functionError.ErrorData
        Return New JsonObject From {{"name", ex.GetType().Name}, {"message", ex.Message}, {"data", data}}
    End Function

    Private Function RequiredString(command As JsonObject, name As String) As String
        Dim value = command(name)?.GetValue(Of String)()
        If String.IsNullOrWhiteSpace(value) Then Throw New InvalidOperationException(name & " is required")
        Return value
    End Function

    Private Function RequiredUrl(value As String) As String
        If String.IsNullOrWhiteSpace(value) Then Throw New InvalidOperationException("CONVEX_URL is required")
        Return value
    End Function

    Private Async Function ReadBoundedLine(input As TextReader) As Task(Of String)
        Dim builder As New Text.StringBuilder()
        Dim one(0) As Char
        While True
            Dim count = Await input.ReadAsync(one, 0, 1)
            If count = 0 Then
                If builder.Length = 0 Then Return Nothing
                Return builder.ToString()
            End If
            If one(0) = ControlChars.Lf Then Return builder.ToString().TrimEnd(ControlChars.Cr)
            If builder.Length >= MaxCommandBytes Then Throw New InvalidOperationException("NDJSON command exceeds 1 MiB")
            builder.Append(one(0))
        End While
        Return Nothing
    End Function

    Private Function LogArray(logs As IReadOnlyList(Of String)) As JsonArray
        Dim result As New JsonArray()
        For Each entry In logs
            result.Add(entry)
        Next
        Return result
    End Function

    Private NotInheritable Class LockedWriter
        Private ReadOnly target As TextWriter
        Private ReadOnly gate As New SemaphoreSlim(1, 1)
        Public Sub New(destination As TextWriter)
            target = destination
        End Sub
        Public Async Function WriteAsync(message As JsonObject) As Task
            Await gate.WaitAsync()
            Try
                Await target.WriteLineAsync(message.ToJsonString(serializer))
                Await target.FlushAsync()
            Finally
                gate.Release()
            End Try
        End Function
    End Class
End Module
