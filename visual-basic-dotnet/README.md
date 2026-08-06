# Convex from Visual Basic .NET

This is a native Visual Basic .NET demonstration of Convex JSON HTTP functions
and the experimental pinned Live sync profile. It is educational, unofficial,
and not a production SDK.

## Start here

[The canonical basic example](examples/basics/Program.vb) reads a counter,
starts Live before changing it, performs an idempotent mutation, and verifies
the resulting Live update. This exact commented source becomes the example
image.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, awaiting root-owned shared evidence |
| Live query subscriptions | Experimental pinned profile, awaiting root-owned shared evidence |
| Authentication | HTTP bearer tokens only |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Program.vb -->
```vbnet
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
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test visual-basic-dotnet
./run build visual-basic-dotnet
```

`test` runs formatting-equivalent compilation and deterministic language-local
tests inside the pinned SDK image. `build` produces the minimal amd64 adapter
runtime. Shared verification is deliberately owned by the root integrator.

## Protocol notes

Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`.
The test-only adapter speaks NDJSON v1 on stdin/stdout or `ADAPTER_LISTEN`, and
offers `debugDisconnect` so the shared harness can prove reconnects. One
owner loop serializes the socket, query-set versions, and reconnects. The
delivery buffer retains the deterministic newest 16 events and bounds their
pessimistically encoded value, error, data, and log output to one MiB per
subscription. The adapter limits a process to eight subscriptions so stopped
near-limit queues remain below the shared 128 MiB process ceiling.

## Limitations

The sync profile is not a documented stable API. Live authentication,
optimistic updates, transition chunks, journals, and replay are intentionally
deferred. No capability badge is claimed until shared local and hosted evidence
is run from a reviewed commit. The final image keeps the .NET 8 runtime, TLS
libraries and CA roots, `/bin/sh`, and the verifier's basic POSIX text tools. It
contains no SDK, compiler, package manager, Perl, Node.js, Python, curl, Convex
CLI, or delegated client runtime.
