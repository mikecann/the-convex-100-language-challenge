Imports System.Net.Http
Imports System.Net.Http.Json
Imports System.Text.Json.Nodes

Namespace ConvexVisualBasic
    ''' <summary>A small native Visual Basic .NET client for Convex JSON HTTP functions.</summary>
    Public NotInheritable Class ConvexClient
        Implements IDisposable

        Private ReadOnly baseUri As Uri
        Private ReadOnly http As New HttpClient With {.Timeout = TimeSpan.FromSeconds(30)}
        Private token As String = ""
        Private closed As Boolean

        Public Sub New(deployment As String)
            Dim candidate As Uri = Nothing
            If Not Uri.TryCreate(deployment.TrimEnd("/"c), UriKind.Absolute, candidate) OrElse
                (candidate.Scheme <> Uri.UriSchemeHttp AndAlso candidate.Scheme <> Uri.UriSchemeHttps) OrElse
                Not String.IsNullOrEmpty(candidate.UserInfo) Then
                Throw New ArgumentException("Convex deployment URL must be http(s), have a host, and omit user info")
            End If
            baseUri = candidate
        End Sub

        Public Sub SetAuth(value As String)
            EnsureOpen()
            token = If(value, "")
        End Sub

        Public Function Query(path As String, args As JsonObject) As Task(Of Result)
            Return CallFunction("query", path, args)
        End Function

        Public Function Mutation(path As String, args As JsonObject) As Task(Of Result)
            Return CallFunction("mutation", path, args)
        End Function

        Public Function Action(path As String, args As JsonObject) As Task(Of Result)
            Return CallFunction("action", path, args)
        End Function

        Private Async Function CallFunction(operation As String, path As String, args As JsonObject) As Task(Of Result)
            EnsureOpen()
            If String.IsNullOrWhiteSpace(path) Then Throw New ArgumentException("Convex function path is required")

            Using request As New HttpRequestMessage(HttpMethod.Post, New Uri(baseUri, "/api/" & operation))
                request.Content = JsonContent.Create(New JsonObject From {
                    {"path", path}, {"args", args.DeepClone()}, {"format", "json"}
                })
                request.Headers.TryAddWithoutValidation("Convex-Client", "visual-basic-dotnet-0.1.0")
                If token.Length <> 0 Then request.Headers.TryAddWithoutValidation("Authorization", "Bearer " & token)

                Dim response As HttpResponseMessage
                Try
                    response = Await http.SendAsync(request).ConfigureAwait(False)
                Catch ex As Exception
                    Throw New TransportException(operation, ex)
                End Try

                Using response
                    Dim decoded As JsonObject
                    Try
                        decoded = Await response.Content.ReadFromJsonAsync(Of JsonObject)().ConfigureAwait(False)
                        If decoded Is Nothing Then Throw New InvalidOperationException("empty response")
                    Catch ex As Exception
                        Throw New TransportException(operation, New InvalidOperationException("non-Convex HTTP response", ex))
                    End Try
                    Dim logs = DecodeLogs(decoded)
                    Dim status = decoded("status")?.GetValue(Of String)()
                    If status = "success" Then
                        If Not decoded.ContainsKey("value") Then Throw New ProtocolException("success response omitted value")
                        Return New Result(If(decoded("value") Is Nothing, Nothing, decoded("value").DeepClone()), logs)
                    End If
                    If status = "error" Then
                        Throw New FunctionException(operation, If(decoded("errorMessage")?.GetValue(Of String)(), "Convex function failed"), decoded("errorData"), logs)
                    End If
                    Throw New ProtocolException("HTTP " & CStr(CInt(response.StatusCode)) & " response has unknown status")
                End Using
            End Using
        End Function

        Friend Shared Function DecodeLogs(message As JsonObject) As IReadOnlyList(Of String)
            Dim values = message("logLines")?.AsArray()
            If values Is Nothing Then Return Array.Empty(Of String)()
            Return values.Select(Function(value) If(value Is Nothing, "", value.GetValue(Of String)())).ToArray()
        End Function

        Private Sub EnsureOpen()
            If closed Then Throw New ObjectDisposedException(NameOf(ConvexClient))
        End Sub

        Public Sub Dispose() Implements IDisposable.Dispose
            closed = True
            http.Dispose()
        End Sub

        Public NotInheritable Class Result
            Public Sub New(resultValue As JsonNode, resultLogs As IReadOnlyList(Of String))
                Value = resultValue
                Logs = resultLogs
            End Sub
            Public ReadOnly Property Value As JsonNode
            Public ReadOnly Property Logs As IReadOnlyList(Of String)
        End Class

        Public Class FunctionException
            Inherits Exception
            Public Sub New(operation As String, message As String, data As JsonNode, logs As IReadOnlyList(Of String))
                MyBase.New(message)
                Me.Operation = operation
                ErrorData = If(data Is Nothing, Nothing, data.DeepClone())
                Me.Logs = logs
            End Sub
            Public ReadOnly Property Operation As String
            Public ReadOnly Property ErrorData As JsonNode
            Public ReadOnly Property Logs As IReadOnlyList(Of String)
        End Class

        Public Class TransportException
            Inherits Exception
            Public Sub New(operation As String, inner As Exception)
                MyBase.New(inner.Message, inner)
                Me.Operation = operation
            End Sub
            Public ReadOnly Property Operation As String
        End Class

        Public Class ProtocolException
            Inherits Exception
            Public Sub New(message As String)
                MyBase.New(message)
            End Sub
        End Class
    End Class
End Namespace
