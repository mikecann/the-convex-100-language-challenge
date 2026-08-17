<img src="logo.png" alt="Visual Basic logo" width="128">
<!-- Logo source: https://github.com/dotnet/brand/blob/main/logo/language-icons/vb-128.png -->

# Visual Basic .NET

Visual Basic .NET is Microsoft's approachable, object-oriented member of the
[.NET language family](https://dotnet.microsoft.com/en-us/languages). It grew
out of the earlier Visual Basic family and shares the .NET runtime and class
libraries with C# and F#. It is still used for Windows desktop applications and
libraries, while Microsoft's current
[language strategy](https://learn.microsoft.com/en-us/dotnet/visual-basic/getting-started/strategy)
favours a stable design and interoperability over expanding into new workloads.

This native Convex client is an educational, unofficial demonstration, not a
production SDK.

## Getting Started

The [canonical basic example](examples/basics/Program.vb) reads a counter over
HTTP, opens a Live subscription, performs an idempotent mutation, and observes
the reactive update. From the repository root, Docker builds and runs that exact
example against an isolated test room:

```sh
./run verify-example visual-basic-dotnet
```

## Interesting Parts

### JSON objects are collection literals, not builder chains

Visual Basic's `From` collection initializer clause lets a `New JsonObject` be
written like a dictionary literal, no chain of `.Add` calls required. Since this
client accepts a raw `JsonObject` for every query and mutation, sending a
request is just writing the JSON by hand.

```vbnet
Dim mutationArgs As New JsonObject From {
    {"room", room},
    {"language", "visual-basic-dotnet"},
    {"runId", Guid.NewGuid().ToString()} ' TypeScript: increment({ room, language, runId })
}

Dim result = Await client.Mutation("demo:increment", mutationArgs)
```

There's no generated `api.demo.increment` reference here — the function path is
just the string `"demo:increment"`, checked by the server at call time.

### Booleans spelled out in full words

Visual Basic's name traces back to Dartmouth BASIC (1964), a language designed
so beginners could read code almost like English, and VB.NET still keeps that
habit in its keywords: `AndAlso`, `OrElse`, `Not`, and `Is Nothing` stand in for
`&&`, `||`, `!`, and `== null`. The client's constructor reads almost like a
sentence when it rejects a bad deployment URL.

```vbnet
If Not Uri.TryCreate(deployment.TrimEnd("/"c), UriKind.Absolute, candidate) OrElse
    (candidate.Scheme <> Uri.UriSchemeHttp AndAlso candidate.Scheme <> Uri.UriSchemeHttps) OrElse
    Not String.IsNullOrEmpty(candidate.UserInfo) Then
    Throw New ArgumentException("Convex deployment URL must be http(s), have a host, and omit user info")
End If
```

### TryCast asks politely; DirectCast does not

Where C# has one `as` operator, VB keeps two verbs for casting. `TryCast`
returns `Nothing` on a bad cast; `DirectCast` throws. Decoding a Live transition
message leans on both within the same function — untrusted server JSON gets the
polite cast, and data this method already validated gets the demanding one.

```vbnet
Dim modification = TryCast(raw, JsonObject) ' Nothing if the server sent something odd.
If modification Is Nothing Then Throw New ConvexClient.ProtocolException("...")
...
version = DirectCast(endVersion.DeepClone(), JsonObject) ' Trusted: already validated above.
```

### A Live subscription is a resource you check out and return

React's `useQuery` opens and tears down a subscription as the component mounts
and unmounts. This client hands you that lifetime directly: `Subscribe` returns
an `IDisposable` `Subscription`, so nesting it inside a `Using` block guarantees
the socket unsubscribes the moment you're done watching, even if an exception
throws through the middle.

```vbnet
Using client As New ConvexClient(url)
    Using live As New LiveClient(url)
        Using subscription = Await live.Subscribe("demo:state", roomArgs)
            Dim initial = subscription.NextUpdate(TimeSpan.FromSeconds(10)) ' TypeScript: useQuery(api.demo.state, { room })
            Await client.Mutation("demo:increment", mutationArgs)
            Dim updated = subscription.NextUpdate(TimeSpan.FromSeconds(10))
        End Using
    End Using
End Using
```

Three nested `Using` blocks close in reverse order the instant control leaves
them — there's no cleanup effect to remember.

## Status

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Live query subscriptions | Verified by shared local and hosted conformance |
| Authentication | HTTP bearer tokens only |

## Example

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

## Implementation Notes

The public client is written in Visual Basic and uses .NET's `HttpClient`,
`System.Text.Json`, and `ClientWebSocket` for transport and JSON. Convex-specific
request envelopes, response validation, errors, subscriptions, and reconnects
are implemented here rather than delegated to another Convex client.

HTTP calls return a `Task(Of Result)`, so ordinary network work composes with
VB's `Async` and `Await` syntax. Results intentionally expose `JsonNode` rather
than generated application types. That keeps this demonstration small, but it
means callers must validate fields and numeric ranges themselves.

Live uses one owner loop for socket reads, writes, subscription changes, and
reconnects. Each subscription retains at most the newest 16 events and one MiB
of pessimistically encoded output. Slow consumers lose older intermediate
values rather than allowing memory to grow without bound. The test-only adapter
speaks the shared protocol and exposes `debugDisconnect`; neither detail is part
of the educational client API.

The Docker build pins .NET SDK 8.0.408 and a .NET 8.0.15 runtime for
`linux/amd64`. The final runtime contains the .NET runtime, TLS support, CA
roots, and the shell tools required by the verifier, but not the SDK, compiler,
package manager, Convex CLI, or another language runtime.

## Known Issues

1. Live targets the pinned, undocumented `convex-rs-0.10.4-unversioned-sync`
   profile at `/api/sync`, not a stable public Convex protocol.
2. Authentication is available for HTTP bearer tokens only. Live
   authentication is not implemented.
3. Optimistic updates, transition chunks, journals, and replay are deferred.
4. A `LiveClient` allows at most eight active subscriptions. Each subscription
   evicts old intermediate updates when its 16-event or one-MiB bound is hit.
