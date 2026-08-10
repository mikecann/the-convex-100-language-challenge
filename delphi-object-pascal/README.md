<img src="logo.png" alt="Free Pascal compiler logo" width="133">
<!-- Logo source: https://www.freepascal.org/pic/logo.gif -->

# Delphi/Object Pascal

Object Pascal adds classes, exceptions, and other application-programming
features to Pascal. Delphi launched in 1995 and remains best known for rapidly
building native Windows applications, while modern Delphi also targets mobile
and cross-platform desktop software through VCL and FireMonkey. See the
[official Delphi site](https://www.embarcadero.com/products/delphi/) for the
commercial IDE and compiler.

This client is not built with Embarcadero Delphi. It uses the open source
[Free Pascal compiler](https://www.freepascal.org/) in Delphi compatibility
mode, which enables Object Pascal language features and makes much Delphi-style
source portable. The Free Pascal logo above identifies the compiler used here,
not an affiliation with the Delphi product. This is an educational,
unofficial demonstration, not a production SDK or a sanctioned Convex client.

## Getting Started

Start with the canonical
[counter example](examples/basics/ConvexExampleApp.pas), which queries a room,
subscribes to it, increments it once, and observes the update without polling
the HTTP endpoint again. From the repository root, Docker builds the pinned
Free Pascal toolchain and runs that exact source against a fresh test room:

```sh
./run verify-example delphi-object-pascal
```

The command checks the program's full six-line output. You do not need Free
Pascal installed on the host.

## Interesting Parts

### A query is a hook in React and an owned result in Pascal

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

const room = "pascal-readme-room";

export function Count() {
  const state = useQuery(api.demo.state, { room });
  if (state === undefined) return <span>Loading...</span>;

  return <span>{state.count}</span>; // The generated API types state.count.
}
```

**Delphi/Object Pascal**

```pascal
uses
  SysUtils, fpjson,
  ConvexClient, ConvexResult;

procedure PrintCount;
var
  Client: TConvexClient;
  Args: TJSONObject;
  QueryResult: TConvexResult;
begin
  Client := TConvexClient.Create(GetEnvironmentVariable('CONVEX_URL'));
  Args := TJSONObject.Create;
  try
    Args.Add('room', 'pascal-readme-room'); // Build Convex's args object.
    QueryResult := Client.Query('demo:state', Args); // One blocking HTTP query.
    try
      WriteLn(TJSONObject(QueryResult.Value).Find('count').AsInteger);
    finally
      QueryResult.Free; // The caller owns the returned result and JSON value.
    end;
  finally
    Args.Free;
    Client.Free;
  end;
end;
```

React's `useQuery` owns a reactive subscription and rerenders when the result
changes. `Client.Query` is deliberately a one-off HTTP call, so this smaller
Pascal example owns its JSON arguments, result object, and cleanup explicitly.

### React manages Live for you; this client exposes the loop

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

const room = "pascal-live-room";

export function LiveCounter() {
  const state = useQuery(api.demo.state, { room }); // React owns the subscription.
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <button disabled>Loading...</button>;
  return (
    <button
      onClick={() => void increment({
        room,
        language: "TypeScript with React",
        runId: `${room}-${crypto.randomUUID()}`, // Fresh idempotency key.
      })}
    >
      Count: {state.count}
    </button>
  ); // A pushed query result causes this component to rerender.
}
```

**Delphi/Object Pascal**

```pascal
uses
  SysUtils, fpjson,
  ConvexClient, ConvexResult;

function NextLiveCount(Client: TConvexClient): Int64;
begin
  repeat
    Client.Live.Poll(200); // This command-line program drives Live itself.
  until Client.Live.PendingEvents.Count > 0;
  Result := TJSONObject(Client.Live.PendingEvents[0].Value)
    .Find('count').AsInteger;
  Client.Live.PendingEvents.Clear; // Clearing also frees the owned event.
end;

procedure IncrementWhileWatching(Client: TConvexClient);
var
  Room: string;
  Args, MutationArgs: TJSONObject;
  MutationResult: TConvexResult;
  Guid: TGUID;
begin
  Room := 'pascal-live-room';
  Args := TJSONObject.Create;
  Args.Add('room', Room);
  try
    Client.Live.AddSubscription('counter', 'demo:state', Args);
    Client.Live.EnsureConnected; // Open one WebSocket and send the subscription.
    WriteLn('initial: ', NextLiveCount(Client));

    MutationArgs := TJSONObject.Create;
    MutationArgs.Add('room', Room);
    MutationArgs.Add('language', 'Delphi/Object Pascal');
    CreateGUID(Guid); // Match React's fresh idempotency key per invocation.
    MutationArgs.Add('runId', Room + '-' + GUIDToString(Guid));
    MutationResult := Client.Mutation('demo:increment', MutationArgs);
    MutationResult.Free; // The update arrives separately through Live.
    MutationArgs.Free;

    WriteLn('updated: ', NextLiveCount(Client)); // Server-pushed result.
    Client.Live.RemoveSubscription('counter');
  finally
    Args.Free;
  end;
end;
```

The Pascal language supports callbacks and threads. The blocking `Poll` call
and visible event list are choices made by this small command-line client so
one owner controls the socket. These snippets show the successful path; the
complete example adds deadlines, checks every result, and guarantees cleanup.

## Status

| Area | Current state |
| --- | --- |
| HTTP query, mutation, action | Implemented, 31/31 shared conformance on both profiles |
| Bearer token lifecycle | Implemented, 31/31 shared conformance on both profiles |
| Live subscribe, update, failure, recovery | Implemented, 31/31 shared conformance on both profiles |
| Live reconnect, replay, rehydration suppression | Implemented, five real reconnects proven on both profiles |
| TLS transport through Free Pascal's socket units | Implemented, proven with real TLS against the hosted deployment |
| NDJSON adapter over stdio and TCP | Implemented, verified |
| Docker build, image hardening, runtime probes | Passing |
| Shared conformance, example verification, hosted drift | 31/31 on both profiles |
| Capability badges | `http`, `live` |

The shared evaluator awarded both badges from a clean exact-head build after
31 of 31 checks passed against the local backend and 31 of 31 passed against
the hosted deployment. The canonical example also matched the shared expected
transcript on both profiles. These are existing recorded results, not a claim
that this README edit reran conformance.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/ConvexExampleApp.pas -->
```pascal
{ Convex from Delphi/Object Pascal: the counter-room walkthrough shown in
  the README and on the project website. It queries the current count over
  HTTP, opens a Live subscription before mutating so the mutation cannot
  race past it, applies one idempotent increment, and shows the resulting
  update arriving over the open WebSocket without polling again. }
program ConvexExampleApp;

{$mode delphi}
{$apptype console}

uses
  SysUtils, BaseUnix, fpjson,
  ConvexClient, ConvexResult, ConvexSyncEvent, ConvexJsonUtil;

// Decode a room state's `count' field into an ordinary Integer. Convex's
// JSON transport may render a whole number as "0.0" rather than "0", so
// this checks the value is actually integral and in range instead of
// truncating a fractional or out-of-range number silently.
function DecodedCount(AState: TJSONData): Integer;
var
  CountField: TJSONData;
begin
  CountField := TJSONObject(AState).Find('count');
  if (CountField = nil) or not IsIntegralNumberInRange(CountField, 0, 1000000) then
  begin
    WriteLn(StdErr, 'count was not a small whole number');
    Halt(1);
  end;
  Result := DecodedInteger(CountField);
end;

// Poll the Live connection until the "basics" subscription reports
// AExpectedCount, or five seconds pass. A single TConvexClient has one
// Live connection and this example holds only one subscription on it, so
// waiting for the very next value is unambiguous.
function WaitForSubscriptionValue(Client: TConvexClient; AExpectedCount: Integer): Boolean;
var
  DeadlineMs: Integer;
  Event: TConvexSyncEvent;
begin
  Result := False;
  DeadlineMs := 5000;
  while (not Result) and (DeadlineMs > 0) do
  begin
    if not Client.Live.IsConnected then
      Client.Live.EnsureConnected;
    if Client.Live.IsConnected then
      Client.Live.Poll(200);
    if Client.Live.PendingEvents.Count > 0 then
    begin
      Event := Client.Live.PendingEvents[0];
      if (not Event.IsError) and (DecodedCount(Event.Value) = AExpectedCount) then
        Result := True;
      Client.Live.PendingEvents.Clear;
    end;
    Dec(DeadlineMs, 200);
  end;
end;

procedure Fail(const AMessage: string);
begin
  WriteLn(StdErr, AMessage);
  Halt(1);
end;

// The verifier's unique room ID when given as the first command-line
// argument, or a friendly default for someone running the image by hand.
function RoomArgument: string;
begin
  if ParamCount >= 1 then
    Result := ParamStr(1)
  else
    Result := 'delphi-object-pascal-basic-example';
end;

procedure Run(Client: TConvexClient; const Room: string);
var
  Args, MutationArgs: TJSONObject;
  StateResult, MutationResult: TConvexResult;
  InitialCount, UpdatedCount: Integer;
  IgnoredOk: Boolean;
begin
  // The public test functions this walkthrough calls need no
  // authentication token, so SetAuth is not used here; see
  // TConvexClient.SetAuth for how a real application would attach a
  // signed-in user's token.

  // The initial HTTP query: read the room's current count before opening
  // the Live subscription, so the printed "current count" line is
  // provably independent of the WebSocket path below.
  Args := TJSONObject.Create;
  Args.Add('room', Room);
  StateResult := Client.Query('demo:state', Args);
  if (StateResult = nil) or not StateResult.IsSuccess then
    Fail('unexpected initial HTTP value');
  InitialCount := DecodedCount(StateResult.Value);
  StateResult.Free;
  if InitialCount <> 0 then
    Fail('unexpected initial HTTP value');
  WriteLn('current count: 0');

  // Start the Live subscription before mutating: opening `/api/sync' and
  // receiving this query's first value here, ahead of the mutation
  // below, is what makes the later "live updated count" line a genuine
  // reactive update rather than a second poll.
  IgnoredOk := Client.Live.AddSubscription('basics', 'demo:state', Args);
  if not IgnoredOk then
    Fail('could not start the Live subscription');
  Client.Live.EnsureConnected;
  if not WaitForSubscriptionValue(Client, InitialCount) then
    Fail('unexpected initial Live value');
  WriteLn('live initial count: 0');

  // The mutation: `runId' is this room's idempotency key, built from the
  // room name so retrying the exact same mutation call never
  // double-counts. A fresh room always starts at count 0, so this is the
  // run that takes it to 1.
  MutationArgs := TJSONObject.Create;
  MutationArgs.Add('room', Room);
  MutationArgs.Add('language', 'Delphi/Object Pascal');
  MutationArgs.Add('runId', Room + '-once');
  MutationResult := Client.Mutation('demo:increment', MutationArgs);
  MutationArgs.Free;
  if (MutationResult = nil) or not MutationResult.IsSuccess
    or not TJSONObject(MutationResult.Value).Find('applied').AsBoolean then
    Fail('unexpected mutation result');
  WriteLn('mutation applied: true');
  UpdatedCount := DecodedCount(TJSONObject(MutationResult.Value).Find('state'));
  MutationResult.Free;
  if UpdatedCount <> 1 then
    Fail('unexpected mutation result');
  WriteLn('mutation count: 1');

  // Wait for the server transition carrying the same updated counter:
  // this is Convex pushing the change to every open subscription, not
  // this client asking again.
  if not WaitForSubscriptionValue(Client, UpdatedCount) then
    Fail('unexpected updated Live value');
  WriteLn('live updated count: 1');

  // Unsubscribe first, then let the client be freed by the caller so its
  // sole transport owner stops cleanly and releases the socket.
  IgnoredOk := Client.Live.RemoveSubscription('basics');
  if not IgnoredOk then
    Fail('could not stop the Live subscription');

  Args.Free;

  // Stdout is deliberately just this one final line plus the five step
  // lines above: the shared verifier compares the whole transcript, so
  // nothing else may print to stdout.
  WriteLn('verified count: 0 -> 1');
end;

var
  DeploymentUrl: string;
  Client: TConvexClient;
  IgnorePipe: SigactionRec;

begin
  // A hosted deployment's connection can reset mid-stream in ordinary
  // operation, and the default SIGPIPE disposition would otherwise kill
  // this whole process the moment a write lands on it.
  FillChar(IgnorePipe, SizeOf(IgnorePipe), 0);
  IgnorePipe.sa_handler := SigActionHandler(SIG_IGN);
  fpsigemptyset(IgnorePipe.sa_mask);
  IgnorePipe.sa_flags := 0;
  fpsigaction(SIGPIPE, @IgnorePipe, nil);

  DeploymentUrl := GetEnvironmentVariable('CONVEX_URL');
  if DeploymentUrl = '' then
    Fail('CONVEX_URL is required');

  // Client creation: parses the deployment URL and prepares (without yet
  // connecting) both the HTTP transport and the Live WebSocket transport
  // this walkthrough uses below.
  Client := TConvexClient.Create(DeploymentUrl);
  try
    Run(Client, RoomArgument);
  finally
    Client.Free;
  end;
end.
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

- The source uses Object Pascal classes and units, and every file selects
  `{$mode delphi}`. Free Pascal's mode enables Delphi-compatible language
  features, but this remains a Free Pascal build rather than a Delphi binary.
- `TConvexClient` is the small public facade. Query, mutation, and action calls
  use Free Pascal's `TFPHTTPClient`; Live uses one WebSocket owned by
  `TConvexSync`. Convex-specific request and update handling stays in Pascal.
- Free Pascal's `fpjson` returns a dynamic JSON tree rather than generated
  application types. `ConvexJsonUtil` therefore rejects fractional,
  non-finite, quoted, and out-of-range values before treating a count as an
  integer.
- `ConvexJsonUtil` also turns on compact JSON and UTF-8 process-wide. Without
  the UTF-8 setting, `AnsiString` can replace non-ASCII characters during
  conversion. Any future executable must import this unit before using JSON.
- The TLS path uses Free Pascal's bundled socket units with SNI and peer
  verification. The client explicitly selects the system CA bundle because
  `TOpenSSLSocketHandler` does not load OpenSSL's default trust paths itself.
  The minimal Debian runtime also supplies unversioned library links because
  Free Pascal 3.2.2 does not search OpenSSL 3's versioned names.
- Docker compiles native `linux/amd64` executables with Free Pascal 3.2.2. The
  final images contain the example or adapter plus runtime libraries, not the
  compiler or a delegated Convex SDK.

## Known Issues

1. `TConvexSync.PendingEvents` is an ordinary owned list with no documented
   count or byte limit. Normal conformance passed under the 128 MiB runtime
   limit, but a stopped consumer receiving near-maximum messages is not proven
   safe by a dedicated stress test.
2. The adapter reports the pinned string `Free Pascal 3.2.2 (Delphi mode)`
   because it cannot introspect the compiler version at run time.
3. Live authentication on an already-open subscription, mutations and actions
   over WebSocket, and optimistic updates are not implemented. They fail
   closed; ordinary mutations and actions still work over HTTP.
4. Compact JSON and UTF-8 behavior depend on the process-wide initialization
   in `ConvexJsonUtil`, so a new executable that omits that unit can produce
   spaced JSON or corrupt non-ASCII text.
