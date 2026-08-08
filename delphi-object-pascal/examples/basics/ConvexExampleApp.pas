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
