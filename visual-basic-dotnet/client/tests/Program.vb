Imports System.Text.Json.Nodes
Imports ConvexVisualBasic

Module Program
    Private Sub AssertTrue(condition As Boolean, message As String)
        If Not condition Then Throw New Exception(message)
    End Sub

    Public Sub Main()
        ' These deterministic unit checks protect the bounded newest-16 delivery contract.
        Dim subscription = New LiveClient.Subscription(Nothing, 1, "demo:state", New JsonObject())
        For value = 0 To 19
            subscription.Offer(New LiveClient.Update(New JsonObject From {{"count", value}}, Nothing, Array.Empty(Of String)()))
        Next
        AssertTrue(subscription.Next(TimeSpan.FromSeconds(1))("count").GetValue(Of Integer)() = 4, "oldest updates were not evicted")
        subscription.Finish()

        Dim client As New ConvexClient("https://example.invalid")
        client.SetAuth("token")
        client.Dispose()
        Try
            client.SetAuth("again")
            Throw New Exception("closed HTTP client accepted authentication")
        Catch expected As ObjectDisposedException
        End Try
        Console.WriteLine("Visual Basic .NET client unit tests passed")
    End Sub
End Module
