# Convex from Delphi/Object Pascal

A native Convex client written in Object Pascal, compiled by Free Pascal in
its `-Mdelphi` compatibility mode. It reads a shared counter over the
documented HTTP API, subscribes to the same query over a WebSocket, applies
one idempotent increment, and proves that the HTTP read, the mutation, and
the live subscription all agree.

This is educational and unofficial. It is not a production SDK, not a
sanctioned Convex client, and not published to any package registry.

## Start here

[examples/basics/ConvexExampleApp.pas](examples/basics/ConvexExampleApp.pas)
is the canonical source and is projected verbatim below. It reads a room's
current count over HTTP, opens a Live subscription before mutating so the
mutation cannot race past it, applies `demo:increment` with a room-derived
idempotency key, and waits for the same change to arrive over the open
WebSocket. It prints six lines and nothing else, and it fails rather than
printing an unexpected value.

## What works

| Area | Current state |
| --- | --- |
| HTTP query, mutation, action | Implemented, 31/31 shared conformance on both profiles |
| Bearer token lifecycle | Implemented, 31/31 shared conformance on both profiles |
| Live subscribe, update, failure, recovery | Implemented, 31/31 shared conformance on both profiles |
| Live reconnect, replay, rehydration suppression | Implemented, five real reconnects proven on both profiles |
| TLS transport (fpc `ssockets`/`sslsockets`/`opensslsockets`) | Implemented, proven with real TLS against the hosted deployment |
| NDJSON adapter over stdio and TCP | Implemented, verified |
| Docker build, image hardening, runtime probes | Passing |
| Shared conformance, example verification, hosted drift | 31/31 on both profiles |
| Capability badges | `http`, `live` |

The shared black-box controller awarded both badges from a clean exact-head
build: 31 of 31 checks against the local self-hosted backend and 31 of 31
against the hosted deployment over real TLS, with the canonical example
byte-compared against the shared transcript on both profiles.

## The basic example

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

## Verify it in Docker

    ./run test delphi-object-pascal
    ./run verify-example delphi-object-pascal
    ./run verify delphi-object-pascal
    ./run verify-hosted delphi-object-pascal

`./run test delphi-object-pascal` builds a `linux/amd64` image that compiles
the client, the adapter, and the example with `fpc -Mdelphi -O2`, asserts the
resulting binaries are genuine x86-64 ELF images (not host-platform binaries
under an amd64 label), runs the deterministic unit-test suite, and probes the
adapter binary over stdio with malformed and well-formed input.
`./run verify-example delphi-object-pascal` runs the exact
`/usr/local/bin/convex-example` entrypoint from the minimal runtime image
against a unique room and compares its six stdout lines to the shared
transcript. `./run verify delphi-object-pascal` adds the shared black-box
conformance suite against the approved local backend, and
`./run verify-hosted delphi-object-pascal` repeats both against the hosted
drift target.

## Conformance and protocol notes

The Live transport implements the `convex-rs 0.10.4` unversioned `/api/sync`
profile pinned in `manifest.yaml`. That endpoint is not a documented,
versioned public API, so an unrecognised envelope fails the connection rather
than being skipped.

Design decisions worth knowing before reading the code:

- **fpc's bundled units, not hand-rolled sockets.** `TConvexSocket`
  (`client/ConvexSocket.pas`) is built on `ssockets`/`sslsockets`/`opensslsockets`.
  `TInetSocket` gives a blocking byte stream, optionally wrapped in TLS through
  `TOpenSSLSocketHandler`, with SNI (`SendHostAsSNI`) and certificate/hostname
  verification (`VerifyPeerCert`) through ordinary published properties. Every
  read carries an explicit millisecond deadline checked with a real `select(2)`
  call, so a stalled or malicious peer cannot block the client's single I/O
  path forever.
- **A documented fpc gap, fixed explicitly.** `TOpenSSLSocketHandler` never
  calls OpenSSL's own `SSL_CTX_set_default_verify_paths`; it only loads a CA
  bundle when one is set explicitly. With `VerifyPeerCert` on and no bundle
  configured, every handshake would fail "certificate verify failed" even
  against a perfectly valid certificate. `DefaultCaBundlePath` locates the
  distro's CA bundle (the runtime image is Debian-based and always installs
  `ca-certificates`) and sets it before every TLS connect.
- **Exact, range-checked numbers.** Convex JSON numbers may render an integral
  value as `0.0` rather than `0`. `ConvexJsonUtil.IsIntegralNumberInRange`
  checks a value is mathematically integral and in range before decoding it,
  so a fractional, quoted, non-finite, or overflowing count is a decoding
  failure rather than a number that silently changed.
- **`debugDisconnect` is adapter-only.** It is implemented in
  `client/tests/conformance/ConvexAdapterApp.pas`, declared in
  `manifest.yaml` under `adapter.adapterOnlyCommands`, and not exposed by
  `TConvexClient`, the unit an ordinary application imports.
- **Two fpc defaults, overridden once, globally.** `fpjson`'s `AsJSON`
  spaces out its output by default, and fpc's `string` (AnsiString) silently
  replaces any non-ASCII character with `?` unless the process's
  `DefaultSystemCodePage` is UTF-8. `ConvexJsonUtil`'s `initialization`
  section sets `TJSONData.CompressedJSON := True` and
  `DefaultSystemCodePage := CP_UTF8` once, before any program logic runs, so
  every JSON value this client sends or receives is compact and every
  non-ASCII byte survives the round trip. Without this, the shared
  conformance suite's UTF-8 tests failed outright (`🟨🟩🟦` round-tripped as
  `??????`).

## Limitations

Honest status, in the order it matters:

- **The Live pending-event list has no documented byte bound.** `TConvexSync`
  appends to an ordinary `TObjectList` and the example drains it. Every Live
  scenario in shared conformance, including five real reconnects, passed
  cleanly under the runtime image's real 128 MiB container limit, but no test
  here specifically drives a stopped or slow consumer with near-maximum
  messages, so that extreme is not proven the way it is for a client with an
  explicit bounded queue and a tested overflow policy.
- **The runtime version is stamped, not introspected.** Free Pascal has no API
  to report its own version at run time, so the adapter's `hello` response
  reports a hardcoded string (`Free Pascal 3.2.2 (Delphi mode)`) matching the
  pinned toolchain rather than an introspected value.
- **Two fpc defaults needed an explicit override to be Convex-safe.** Free
  Pascal's `TJSONData.AsJSON` inserts a space after every `:` and `,` by
  default, and its `string` type (AnsiString) silently mangles any character
  outside plain ASCII into `?` unless `DefaultSystemCodePage` is set to
  `CP_UTF8`. Both are process-global settings applied once in
  `ConvexJsonUtil`'s `initialization` section; any new program entrypoint
  must still import that unit before touching JSON or the wire.
- **Deferred protocol behaviour.** Live authentication against an already-open
  subscription, WebSocket mutations and actions, and optimistic updates are
  not implemented and fail closed.
- **Capability badges are earned.** `capabilities` in `manifest.yaml` lists
  `http` and `live`, awarded by the shared evaluator from a clean exact-head
  build (`39ef24f52a417ee3fdc75b53d34e0881e1a76770`).
