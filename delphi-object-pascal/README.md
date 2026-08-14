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

### One directive turns Free Pascal into Delphi

Pascal configures its own compiler with `{$...}` directives right in the
source. This client is built with the open source Free Pascal compiler, and a
single line per file switches it into Delphi compatibility mode.

```pascal
program ConvexExampleApp;

{$mode delphi}    { Free Pascal, speaking the Delphi dialect }
{$apptype console}

uses
  SysUtils, fpjson,
  ConvexClient, ConvexResult, ConvexSyncEvent, ConvexJsonUtil;
```

### The query result is yours — and yours to Free

Object Pascal has no garbage collector; the Delphi idiom since 1995 is one
`try..finally` per owned object. `Client.Query` returns a `TConvexResult`
that the caller owns, so cleanup is part of the call's visible shape.

```pascal
Args := TJSONObject.Create;
Args.Add('room', Room);
try
  // TypeScript: const state = useQuery(api.demo.state, { room })
  StateResult := Client.Query('demo:state', Args);
  try
    if StateResult.IsSuccess then
      WriteLn('count: ', TJSONObject(StateResult.Value).Find('count').AsInteger);
  finally
    StateResult.Free;  { frees the result and its decoded JSON tree }
  end;
finally
  Args.Free;
end;
```

### Properties: fields on the outside, getters underneath

Delphi's `property` keyword — the 1995 feature that made drag-and-drop
component design work, and that Anders Hejlsberg later carried into C# —
publishes read-only views of private state. `TConvexResult` uses it to make
the success/failure split feel like plain data access.

```pascal
{ From ConvexResult.pas: read-only windows onto private fields. }
property IsSuccess: Boolean read FIsSuccess;
property Value: TJSONData read FValue;
property ErrorMessage: string read FErrorMessage;

{ At the call site a property reads like a field: }
if not MutationResult.IsSuccess then
  WriteLn(StdErr, MutationResult.ErrorMessage);
```

### repeat..until the server pushes

Pascal's post-condition loop reads almost like English, and this client keeps
Convex's reactive side visible enough to use one: subscribe, pump the
WebSocket, and every server push lands as a `TConvexSyncEvent` in
`PendingEvents`. No hidden scheduler — your program is the event loop.

```pascal
Client.Live.AddSubscription('basics', 'demo:state', Args);
Client.Live.EnsureConnected;  { one WebSocket, one owner }

repeat
  Client.Live.Poll(200);  { pump the socket for up to 200 ms }
until Client.Live.PendingEvents.Count > 0;

// TypeScript: useQuery(api.demo.state, { room }) rerenders on this same push
Event := Client.Live.PendingEvents[0];
if not Event.IsError then
  WriteLn('live count: ', TJSONObject(Event.Value).Find('count').AsInteger);
Client.Live.PendingEvents.Clear;  { the list owns and frees its events }
```

Mutate the room from anywhere — even another process — and the update arrives
on this socket without querying again.

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
