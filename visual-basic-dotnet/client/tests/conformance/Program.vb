Imports System.Collections.Concurrent
Imports System.IO
Imports System.Net
Imports System.Net.Sockets
Imports System.Text
Imports System.Text.Json
Imports System.Text.Json.Nodes
Imports System.Text.Json.Serialization.Metadata
Imports System.Threading
Imports ConvexVisualBasic

''' <summary>Strict test-only NDJSON adapter v1. Every operation calls the native VB.NET client.</summary>
Public Module Program
    Private Const MaxCommandBytes As Integer = 1048576
    Private Const MaxSubscriptions As Integer = 8
    Private ReadOnly StrictUtf8 As New UTF8Encoding(False, True)
    ' JsonNode serialization reaches the final adapter's stdout path. An empty
    ' options instance is not safe once System.Text.Json freezes it in trimmed
    ' runtime configurations, so give it an explicit metadata resolver.
    Private ReadOnly Serializer As New JsonSerializerOptions() With {
        .TypeInfoResolver = New DefaultJsonTypeInfoResolver()
    }
    Public RelayBeforeWriter As Func(Of Task)

    Public Sub Main(args As String())
        MainAsync().GetAwaiter().GetResult()
    End Sub

    Private Async Function MainAsync() As Task
        Dim listen = Environment.GetEnvironmentVariable("ADAPTER_LISTEN")
        If String.IsNullOrWhiteSpace(listen) Then
            Using input As New StreamReader(Console.OpenStandardInput(), StrictUtf8, False, 4096, True)
                Using output As New StreamWriter(Console.OpenStandardOutput(), New UTF8Encoding(False), 4096, True) With {.AutoFlush = True}
                    Await Run(input, output, Environment.GetEnvironmentVariable("CONVEX_URL"))
                End Using
            End Using
            Return
        End If

        Dim parts = listen.Split(":"c)
        If parts.Length <> 2 Then Throw New InvalidOperationException("ADAPTER_LISTEN must be host:port")
        Dim server As New TcpListener(IPAddress.Parse(parts(0)), Integer.Parse(parts(1)))
        server.Start()
        Try
            Using accepted = Await server.AcceptTcpClientAsync()
                accepted.NoDelay = True
                Using stream = accepted.GetStream()
                    Using input As New StreamReader(stream, StrictUtf8, False, 4096, True)
                        Using output As New StreamWriter(stream, New UTF8Encoding(False), 4096, True) With {.AutoFlush = True}
                            Await Run(input, output, Environment.GetEnvironmentVariable("CONVEX_URL"))
                        End Using
                    End Using
                End Using
            End Using
        Finally
            server.Stop()
        End Try
    End Function

    Public Async Function Run(input As TextReader, output As TextWriter, url As String) As Task
        Dim writer As New LockedWriter(output)
        Dim subscriptions As New ConcurrentDictionary(Of String, LiveClient.Subscription)()
        Dim relays As New ConcurrentDictionary(Of String, RelayState)()
        Dim client As ConvexClient = Nothing
        Dim live As LiveClient = Nothing
        Try
            While True
                Dim line As String = Nothing
                Dim inputFailure As Exception = Nothing
                Try
                    line = Await ReadBoundedLine(input)
                Catch ex As Exception
                    inputFailure = ex
                End Try
                If inputFailure IsNot Nothing Then
                    Await writer.WriteAsync(Failure(Nothing, New ConvexClient.ProtocolException(inputFailure.Message)))
                    Return
                End If
                If line Is Nothing Then Return

                Dim command As JsonObject = Nothing
                Dim commandId As String = Nothing
                Dim commandFailure As Exception = Nothing
                Try
                    command = TryCast(JsonNode.Parse(line), JsonObject)
                    If command Is Nothing Then Throw New ConvexClient.ProtocolException("command must be a JSON object")
                    commandId = RequiredId(command)
                    Dim op = RequiredOperation(command)
                    ValidateShape(command, op)
                    Select Case op
                        Case "hello"
                            If RequiredInteger(command, "protocolVersion") <> 1 Then Throw New ConvexClient.ProtocolException("unsupported protocol version")
                            Await writer.WriteAsync(New JsonObject From {
                                {"protocolVersion", 1}, {"id", commandId}, {"type", "ready"},
                                {"language", "visual-basic-dotnet"}, {"implementation", "native-visual-basic-dotnet-0.2.0"},
                                {"runtime", Environment.Version.ToString()}
                            })
                        Case "query", "mutation", "action"
                            If client Is Nothing Then client = New ConvexClient(RequiredUrl(url))
                            Dim args = RequiredObject(command, "args")
                            Dim path = RequiredText(command, "path")
                            Dim result As ConvexClient.Result
                            If op = "query" Then
                                result = Await client.Query(path, args)
                            ElseIf op = "mutation" Then
                                result = Await client.Mutation(path, args)
                            Else
                                result = Await client.Action(path, args)
                            End If
                            Dim response As New JsonObject From {{"id", commandId}, {"type", "result"}, {"logs", LogArray(result.Logs)}}
                            ' Assigning Nothing to an existing JsonObject property serializes a real JSON null.
                            response("value") = If(result.Value Is Nothing, Nothing, result.Value.DeepClone())
                            Await writer.WriteAsync(response)
                        Case "setAuth"
                            If client Is Nothing Then client = New ConvexClient(RequiredUrl(url))
                            client.SetAuth(RequiredToken(command))
                            Await writer.WriteAsync(Ack(commandId))
                        Case "subscribe"
                            Dim subscriptionId = RequiredSubscriptionId(command)
                            Dim path = RequiredText(command, "path")
                            Dim args = RequiredObject(command, "args")
                            ' A same-ID replacement first retires the old relay and Live query.
                            ' Its freed slot is therefore visible to both cap checks before Add.
                            Invalidate(subscriptionId, subscriptions, relays)
                            If subscriptions.Count >= MaxSubscriptions Then Throw New ConvexClient.ProtocolException("adapter subscription limit is 8")
                            If live Is Nothing Then live = New LiveClient(RequiredUrl(url))
                            Dim subscription = Await live.Subscribe(path, args)
                            If Not subscriptions.TryAdd(subscriptionId, subscription) Then Throw New InvalidOperationException("subscription replacement failed")
                            Await writer.WriteAsync(Ack(commandId))
                            Dim relayState = New RelayState()
                            relays(subscriptionId) = relayState
                            relayState.Task = Relay(subscriptionId, subscription, relayState.Cancellation.Token, subscriptions, writer)
                        Case "unsubscribe"
                            Dim subscriptionId = RequiredSubscriptionId(command)
                            Invalidate(subscriptionId, subscriptions, relays)
                            Await writer.WriteAsync(Ack(commandId))
                        Case "debugDisconnect"
                            If live Is Nothing Then Throw New ConvexClient.ProtocolException("no active Live connection")
                            Await live.DebugDisconnect()
                            Await writer.WriteAsync(Ack(commandId))
                        Case "close"
                            InvalidateAll(subscriptions, relays)
                            If live IsNot Nothing Then Await live.CloseAsync().WaitAsync(TimeSpan.FromSeconds(4))
                            client?.Dispose()
                            Await writer.WriteAsync(New JsonObject From {{"id", commandId}, {"type", "closed"}})
                            Return
                    End Select
                Catch ex As JsonException
                    commandFailure = New ConvexClient.ProtocolException("invalid NDJSON command: " & ex.Message)
                Catch ex As AdapterOutputException
                    Throw
                Catch ex As Exception
                    commandFailure = ex
                End Try
                If commandFailure IsNot Nothing Then Await writer.WriteAsync(Failure(commandId, commandFailure))
            End While
        Finally
            InvalidateAll(subscriptions, relays)
            If live IsNot Nothing Then
                Try
                    live.CloseAsync().WaitAsync(TimeSpan.FromSeconds(4)).GetAwaiter().GetResult()
                Catch ex As Exception
                End Try
            End If
            client?.Dispose()
            AwaitRelays(relays.Values).GetAwaiter().GetResult()
        End Try
    End Function

    Private Sub Invalidate(subscriptionId As String, subscriptions As ConcurrentDictionary(Of String, LiveClient.Subscription), relays As ConcurrentDictionary(Of String, RelayState))
        Dim relay As RelayState = Nothing
        If relays.TryRemove(subscriptionId, relay) Then relay.Cancellation.Cancel()
        Dim subscription As LiveClient.Subscription = Nothing
        If subscriptions.TryRemove(subscriptionId, subscription) Then subscription.Dispose()
    End Sub

    Private Sub InvalidateAll(subscriptions As ConcurrentDictionary(Of String, LiveClient.Subscription), relays As ConcurrentDictionary(Of String, RelayState))
        For Each state In relays.Values
            state.Cancellation.Cancel()
        Next
        subscriptions.Clear()
    End Sub

    Private Async Function AwaitRelays(states As IEnumerable(Of RelayState)) As Task
        Dim tasks = states.Select(Function(state) state.Task).Where(Function(task) task IsNot Nothing).ToArray()
        If tasks.Length = 0 Then Return
        Try
            Await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(2))
        Catch ex As Exception
        End Try
    End Function

    Private Async Function Relay(subscriptionId As String, subscription As LiveClient.Subscription, cancellation As CancellationToken, subscriptions As ConcurrentDictionary(Of String, LiveClient.Subscription), writer As LockedWriter) As Task
        While Not cancellation.IsCancellationRequested
            Dim update As LiveClient.Update
            Try
                update = Await Task.Run(Function() subscription.NextUpdate(TimeSpan.FromMilliseconds(200)), cancellation)
            Catch ex As TimeoutException
                Continue While
            Catch ex As Exception When TypeOf ex Is OperationCanceledException OrElse cancellation.IsCancellationRequested
                Return
            End Try

            Dim message As New JsonObject From {{"type", "subscription"}, {"subscriptionId", subscriptionId}}
            If update.Error Is Nothing Then
                message("value") = If(update.Value Is Nothing, Nothing, update.Value.DeepClone())
                message("logs") = LogArray(update.Logs)
            Else
                message("error") = ErrorObject(update.Error)
            End If

            ' The current-subscription identity check executes while the same writer lock
            ' that publishes acknowledgements is held. A stale relay can only appear before
            ' an unsubscribe/replacement acknowledgement, never after it.
            If RelayBeforeWriter IsNot Nothing Then Await RelayBeforeWriter()
            Dim written = Await writer.WriteIfAsync(
                Function()
                    Dim current As LiveClient.Subscription = Nothing
                    Return subscriptions.TryGetValue(subscriptionId, current) AndAlso Object.ReferenceEquals(current, subscription)
                End Function,
                message
            )
            If Not written Then Return
        End While
    End Function

    Private Function Ack(id As String) As JsonObject
        Return New JsonObject From {{"id", id}, {"type", "ack"}}
    End Function

    Private Function Failure(id As String, ex As Exception) As JsonObject
        Dim response As New JsonObject From {{"type", "error"}, {"error", ErrorObject(ex)}}
        If id IsNot Nothing Then response("id") = id
        Return response
    End Function

    Private Function ErrorObject(ex As Exception) As JsonObject
        Dim response As New JsonObject From {{"name", CanonicalErrorName(ex)}, {"message", ex.Message}}
        Dim functionError = TryCast(ex, ConvexClient.FunctionException)
        If functionError IsNot Nothing AndAlso functionError.ErrorData IsNot Nothing Then response("data") = functionError.ErrorData.DeepClone()
        Return response
    End Function

    Private Function CanonicalErrorName(ex As Exception) As String
        If TypeOf ex Is ConvexClient.FunctionException Then Return "FunctionError"
        If TypeOf ex Is ConvexClient.ProtocolException Then Return "ProtocolError"
        If TypeOf ex Is ConvexClient.TransportException Then Return "TransportError"
        Return "Error"
    End Function

    Private Function RequiredId(command As JsonObject) As String
        Return RequiredBoundedIdentifier(command, "id")
    End Function

    Private Function RequiredSubscriptionId(command As JsonObject) As String
        Return RequiredBoundedIdentifier(command, "subscriptionId")
    End Function

    Private Function RequiredBoundedIdentifier(command As JsonObject, name As String) As String
        Dim result = RequiredText(command, name)
        If result.Length > 128 Then Throw New ConvexClient.ProtocolException(name & " exceeds 128 characters")
        Return result
    End Function

    Private Function RequiredOperation(command As JsonObject) As String
        Dim result = RequiredText(command, "op")
        Dim allowed = New HashSet(Of String) From {"hello", "query", "mutation", "action", "setAuth", "subscribe", "unsubscribe", "debugDisconnect", "close"}
        If Not allowed.Contains(result) Then Throw New ConvexClient.ProtocolException("unknown operation: " & result)
        Return result
    End Function

    Private Function RequiredText(command As JsonObject, name As String) As String
        If Not command.ContainsKey(name) OrElse command(name) Is Nothing Then Throw New ConvexClient.ProtocolException(name & " is required")
        Try
            Dim result = command(name).GetValue(Of String)()
            If result.Length = 0 Then Throw New ConvexClient.ProtocolException(name & " is required")
            Return result
        Catch ex As ConvexClient.ProtocolException
            Throw
        Catch ex As Exception
            Throw New ConvexClient.ProtocolException(name & " must be a string")
        End Try
    End Function

    Private Function RequiredToken(command As JsonObject) As String
        If Not command.ContainsKey("token") OrElse command("token") Is Nothing Then Throw New ConvexClient.ProtocolException("token must be a string")
        Try
            Return command("token").GetValue(Of String)()
        Catch ex As Exception
            Throw New ConvexClient.ProtocolException("token must be a string")
        End Try
    End Function

    Private Function RequiredInteger(command As JsonObject, name As String) As Integer
        If Not command.ContainsKey(name) OrElse command(name) Is Nothing Then Throw New ConvexClient.ProtocolException(name & " is required")
        Try
            Return command(name).GetValue(Of Integer)()
        Catch ex As Exception
            Throw New ConvexClient.ProtocolException(name & " must be an integer")
        End Try
    End Function

    Private Function RequiredObject(command As JsonObject, name As String) As JsonObject
        Dim result = TryCast(command(name), JsonObject)
        If result Is Nothing Then Throw New ConvexClient.ProtocolException(name & " must be an object")
        Return result
    End Function

    Private Sub ValidateShape(command As JsonObject, op As String)
        Dim allowed As HashSet(Of String)
        Select Case op
            Case "hello"
                allowed = New HashSet(Of String) From {"protocolVersion", "id", "op"}
            Case "query", "mutation", "action"
                allowed = New HashSet(Of String) From {"id", "op", "path", "args"}
            Case "setAuth"
                allowed = New HashSet(Of String) From {"id", "op", "token"}
            Case "subscribe"
                allowed = New HashSet(Of String) From {"id", "op", "subscriptionId", "path", "args"}
            Case "unsubscribe"
                allowed = New HashSet(Of String) From {"id", "op", "subscriptionId"}
            Case Else
                allowed = New HashSet(Of String) From {"id", "op"}
        End Select
        For Each propertyName In command.Select(Function(entry) entry.Key)
            If Not allowed.Contains(propertyName) Then Throw New ConvexClient.ProtocolException("unexpected command field: " & propertyName)
        Next
    End Sub

    Private Function RequiredUrl(value As String) As String
        If String.IsNullOrWhiteSpace(value) Then Throw New ConvexClient.ProtocolException("CONVEX_URL is required")
        Return value
    End Function

    Private Async Function ReadBoundedLine(input As TextReader) As Task(Of String)
        Dim builder As New StringBuilder()
        Dim one(0) As Char
        Dim bytes As Integer
        Dim pendingHighSurrogate As Boolean
        While True
            Dim count = Await input.ReadAsync(one, 0, 1)
            If count = 0 Then
                If pendingHighSurrogate Then Throw New ConvexClient.ProtocolException("incomplete UTF-16 surrogate in command")
                If builder.Length = 0 Then Return Nothing
                Return builder.ToString()
            End If
            Dim character = one(0)
            If character = ControlChars.Lf Then
                If pendingHighSurrogate Then Throw New ConvexClient.ProtocolException("incomplete UTF-16 surrogate in command")
                Return builder.ToString().TrimEnd(ControlChars.Cr)
            End If
            If Char.IsHighSurrogate(character) Then
                If pendingHighSurrogate Then Throw New ConvexClient.ProtocolException("invalid UTF-16 surrogate in command")
                pendingHighSurrogate = True
            ElseIf Char.IsLowSurrogate(character) Then
                If Not pendingHighSurrogate Then Throw New ConvexClient.ProtocolException("invalid UTF-16 surrogate in command")
                pendingHighSurrogate = False
                bytes += 4
            Else
                If pendingHighSurrogate Then Throw New ConvexClient.ProtocolException("invalid UTF-16 surrogate in command")
                bytes += If(AscW(character) <= &H7F, 1, If(AscW(character) <= &H7FF, 2, 3))
            End If
            If bytes > MaxCommandBytes Then Throw New ConvexClient.ProtocolException("NDJSON command exceeds 1 MiB of UTF-8")
            builder.Append(character)
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

    Private NotInheritable Class RelayState
        Public ReadOnly Cancellation As New CancellationTokenSource()
        Public Property Task As Task
    End Class

    Public NotInheritable Class LockedWriter
        Private ReadOnly target As TextWriter
        Private ReadOnly gate As New SemaphoreSlim(1, 1)

        Public Sub New(destination As TextWriter)
            target = destination
        End Sub

        Public Function WriteAsync(message As JsonObject) As Task(Of Boolean)
            Return WriteIfAsync(Function() True, message)
        End Function

        Public Async Function WriteIfAsync(stillCurrent As Func(Of Boolean), message As JsonObject) As Task(Of Boolean)
            Using bounded As New CancellationTokenSource(TimeSpan.FromSeconds(3))
                Try
                    Await gate.WaitAsync(bounded.Token)
                    Try
                        If Not stillCurrent() Then Return False
                        Dim payload = message.ToJsonString(Serializer)
                        Await target.WriteLineAsync(payload.AsMemory(), bounded.Token)
                        Await target.FlushAsync(bounded.Token)
                        Return True
                    Finally
                        gate.Release()
                    End Try
                Catch ex As Exception When TypeOf ex Is OperationCanceledException OrElse TypeOf ex Is IOException OrElse TypeOf ex Is ObjectDisposedException
                    Throw New AdapterOutputException("adapter output did not accept a bounded write", ex)
                End Try
            End Using
        End Function
    End Class

    Private NotInheritable Class AdapterOutputException
        Inherits IOException
        Public Sub New(message As String, inner As Exception)
            MyBase.New(message, inner)
        End Sub
    End Class
End Module
