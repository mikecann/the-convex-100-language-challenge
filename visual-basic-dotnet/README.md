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

### JSON objects use collection initializers

In React, a plain object becomes the mutation arguments. This VB client accepts
`JsonObject`, so its `From` collection initializer plays the same role.

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);
  const room = "vb-readme-room";

  return (
    <button
      onClick={() =>
        increment({
          room,
          language: "typescript",
          runId: crypto.randomUUID(), // Makes a retry safe.
        })
      }
    >
      Increment
    </button>
  );
}
```

**Visual Basic .NET**

```vbnet
Imports System
Imports System.Text.Json.Nodes
Imports System.Threading.Tasks
Imports ConvexVisualBasic

Module IncrementExample
    Public Async Function IncrementAsync() As Task
        Dim url = Environment.GetEnvironmentVariable("CONVEX_URL")
        If String.IsNullOrWhiteSpace(url) Then Throw New InvalidOperationException("CONVEX_URL is required")

        Dim room = "vb-readme-room"
        Dim mutationArgs As New JsonObject From {
            {"room", room},
            {"language", "visual-basic-dotnet"},
            {"runId", Guid.NewGuid().ToString()} ' Makes a retry safe.
        }

        Using client As New ConvexClient(url)
            Dim result = Await client.Mutation("demo:increment", mutationArgs)
            Dim mutation = result.Value.AsObject() ' The returned JSON remains explicit.
            Dim state = mutation("state").AsObject()
            Console.WriteLine(state("count"))
        End Using
    End Function
End Module
```

The VB initializer is concise, but it is not a generated, type-safe function
reference. Function paths and returned JSON fields are checked at runtime. The
[full example](examples/basics/Program.vb) adds strict numeric decoding and
checks the mutation result before trusting it.

### The command-line client owns the Live subscription

React starts, updates, and disposes the `useQuery` subscription with the
component. This VB API deliberately exposes a blocking `Next` operation so a
small console program can control exactly when it observes each value. That is
a choice made by this client, not a limitation of Visual Basic or .NET.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const room = "vb-readme-room";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <p>Loading...</p>;
  return (
    <>
      <p>Count: {state.count}</p> {/* React re-renders after updates. */}
      <button
        onClick={() =>
          void increment({
            room,
            language: "typescript",
            runId: crypto.randomUUID(),
          })
        }
      >
        Increment
      </button>
    </>
  );
}
```

**Visual Basic .NET**

```vbnet
Imports System
Imports System.Text.Json.Nodes
Imports System.Threading.Tasks
Imports ConvexVisualBasic

Module LiveExample
    Public Async Function ObserveAsync() As Task
        Dim url = Environment.GetEnvironmentVariable("CONVEX_URL")
        If String.IsNullOrWhiteSpace(url) Then Throw New InvalidOperationException("CONVEX_URL is required")

        Dim room = "vb-readme-room"
        Dim queryArgs As New JsonObject From {{"room", room}}

        Using client As New ConvexClient(url)
            Using live As New LiveClient(url)
                ' Subscribe owns the server query until this object is disposed.
                Using subscription = Await live.Subscribe("demo:state", queryArgs)
                    Dim initial = subscription.Next(TimeSpan.FromSeconds(10)).AsObject()
                    Console.WriteLine(initial("count")) ' The first available value.

                    Dim mutationArgs As New JsonObject From {
                        {"room", room},
                        {"language", "visual-basic-dotnet"},
                        {"runId", Guid.NewGuid().ToString()}
                    }
                    Dim result = Await client.Mutation("demo:increment", mutationArgs)
                    Dim mutation = result.Value.AsObject()
                    Console.WriteLine(mutation("applied")) ' The mutation's returned value.

                    Dim updated = subscription.Next(TimeSpan.FromSeconds(10)).AsObject()
                    Console.WriteLine(updated("count")) ' The resulting reactive value.
                End Using
            End Using
        End Using
    End Function
End Module
```

The React component leaves subscription cleanup and rerendering to the hook.
The VB fragment explicitly owns both clients and pulls each value in order. The
canonical example adds checks that the initial query, mutation result, and Live
update all agree.

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
