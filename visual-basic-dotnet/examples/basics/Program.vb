Imports System.Text.Json.Nodes
Imports ConvexVisualBasic

Module Program
    Public Sub Main(args As String())
        MainAsync(args).GetAwaiter().GetResult()
    End Sub

    Private Async Function MainAsync(args As String()) As Task
        ' Read the verifier's deployment rather than baking any service URL into the image.
        Dim url = Environment.GetEnvironmentVariable("CONVEX_URL")
        If String.IsNullOrWhiteSpace(url) Then Throw New InvalidOperationException("CONVEX_URL is required")

        ' Each run owns a room, so parallel examples cannot change this counter.
        Dim room = If(args.Length = 0, "visual-basic-dotnet-example", args(0))
        Dim roomArgs As New JsonObject From {{"room", room}}

        ' The native HTTP and Live clients are both cleaned up if one observation fails.
        Using client As New ConvexClient(url)
            Using live As New LiveClient(url)
                ' HTTP is the initial source of truth before opening the reactive query.
                Dim before = CountValue.Read((Await client.Query("demo:state", roomArgs)).Value, "current query")

                ' Start Live before the mutation so its first value establishes the observation point.
                Using subscription = Await live.Subscribe("demo:state", roomArgs)
                    Dim initial = CountValue.Read(subscription.Next(TimeSpan.FromSeconds(10)), "initial Live value")
                    If initial <> before Then Throw New InvalidOperationException("Live initial value disagreed")

                    ' runId makes retries idempotent and lets the backend report whether it applied this increment.
                    Dim mutation = Await client.Mutation("demo:increment", New JsonObject From {
                        {"room", room}, {"language", "visual-basic-dotnet"}, {"runId", Guid.NewGuid().ToString()}
                    })
                    Dim mutationValue = mutation.Value?.AsObject()
                    If mutationValue Is Nothing OrElse Not mutationValue("applied").GetValue(Of Boolean)() Then Throw New InvalidOperationException("mutation was not applied")
                    Dim after = CountValue.Read(mutationValue("state"), "mutation")
                    If after <> before + 1 Then Throw New InvalidOperationException("mutation count was unexpected")

                    ' The second Live value must agree with the mutation before stdout records the universal transcript.
                    Dim updated = CountValue.Read(subscription.Next(TimeSpan.FromSeconds(10)), "updated Live value")
                    If updated <> after Then Throw New InvalidOperationException("Live update disagreed")
                    Console.WriteLine("current count: " & before)
                    Console.WriteLine("live initial count: " & initial)
                    Console.WriteLine("mutation applied: true")
                    Console.WriteLine("mutation count: " & after)
                    Console.WriteLine("live updated count: " & updated)
                    Console.WriteLine("verified count: " & before & " -> " & updated)
                End Using
            End Using
        End Using
    End Function
End Module
