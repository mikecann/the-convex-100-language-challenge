{ The test-only executable that exposes TConvexClient through NDJSON
  adapter protocol v1 (see docs/conformance.md in the repository root) for
  the shared black-box controller. It is not part of the public client
  API: client/tests/conformance/ code is test infrastructure the
  educational client never imports.

  This process is the one I/O owner of both the control stream and the
  Live WebSocket (see TConvexSync's header comment): the loop below is the
  single place that ever touches either, alternating between them with one
  bounded select per iteration so neither a silent controller nor a
  stalled server can block the other. }
program ConvexAdapterApp;

{$mode delphi}
{$apptype console}

uses
  SysUtils, Classes, BaseUnix, fpjson, jsonparser,
  ConvexClient, ConvexResult, ConvexSync, ConvexSyncEvent, ConvexJsonUtil,
  ConvexControlStream;

const
  PollIntervalMs = 200;
  RuntimeVersion = 'Free Pascal 3.2.2 (Delphi mode)';

var
  GClient: TConvexClient;
  GControl: TConvexControlStream;
  GClosed: Boolean;
  GLiveCreated: Boolean;

// Waits up to ATimeoutMs for either descriptor to become readable.
// Returns 0 (neither ready), 1 (only AFdOne), 2 (only AFdTwo), or 3
// (both). Pass -1 for a descriptor that should not be watched, for
// example while no Live subscription has an open socket yet.
function WaitReadableTwo(AFdOne, AFdTwo: cint; ATimeoutMs: Integer): Integer;
var
  ReadSet: TFDSet;
  TimeVal: TTimeVal;
  Rc, MaxFd: cint;
begin
  fpFD_ZERO(ReadSet);
  MaxFd := -1;
  if AFdOne >= 0 then
  begin
    fpFD_SET(AFdOne, ReadSet);
    if AFdOne > MaxFd then
      MaxFd := AFdOne;
  end;
  if AFdTwo >= 0 then
  begin
    fpFD_SET(AFdTwo, ReadSet);
    if AFdTwo > MaxFd then
      MaxFd := AFdTwo;
  end;
  TimeVal.tv_sec := ATimeoutMs div 1000;
  TimeVal.tv_usec := (ATimeoutMs mod 1000) * 1000;
  if MaxFd < 0 then
  begin
    // Nothing to watch; still honour the timeout so a caller polling in
    // a loop does not spin.
    repeat
      Rc := fpSelect(0, nil, nil, nil, @TimeVal);
    until (Rc >= 0) or (fpgeterrno <> ESysEINTR);
    Exit(0);
  end;
  repeat
    Rc := fpSelect(MaxFd + 1, @ReadSet, nil, nil, @TimeVal);
  until (Rc >= 0) or (fpgeterrno <> ESysEINTR);
  Result := 0;
  if Rc > 0 then
  begin
    if (AFdOne >= 0) and (fpFD_ISSET(AFdOne, ReadSet) = 1) then
      Result := Result or 1;
    if (AFdTwo >= 0) and (fpFD_ISSET(AFdTwo, ReadSet) = 1) then
      Result := Result or 2;
  end;
end;

function LiveOpen: Boolean;
begin
  Result := GLiveCreated and GClient.Live.IsConnected;
end;

procedure MaybeEnsureLiveConnected;
begin
  if GLiveCreated and not GClient.Live.IsConnected then
    GClient.Live.EnsureConnected;
end;

// -- JSON helpers -----------------------------------------------------

function StringField(AObject: TJSONData; const AKey: string; out AValue: string): Boolean;
var
  Field: TJSONData;
begin
  Result := False;
  if not HasField(AObject, AKey) then
    Exit;
  Field := TJSONObject(AObject).Find(AKey);
  if Field.JSONType <> jtString then
    Exit;
  AValue := Field.AsString;
  Result := True;
end;

function ObjectField(AObject: TJSONData; const AKey: string; out AValue: TJSONData): Boolean;
var
  Field: TJSONData;
begin
  Result := False;
  if not HasField(AObject, AKey) then
    Exit;
  Field := TJSONObject(AObject).Find(AKey);
  if Field.JSONType <> jtObject then
    Exit;
  AValue := Field;
  Result := True;
end;

function StringValue(const AText: string): TJSONData;
begin
  Result := TJSONString.Create(AText);
end;

function LogsValue(ALogs: TStrings): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  if ALogs <> nil then
    for I := 0 to ALogs.Count - 1 do
      Result.Add(ALogs[I]);
end;

// -- Event emission -----------------------------------------------------

procedure WriteEvent(AEvent: TJSONObject);
begin
  try
    GControl.WriteLine(AEvent.AsJSON);
  finally
    AEvent.Free;
  end;
end;

procedure SendReady(const AId: string);
var
  Event: TJSONObject;
begin
  Event := TJSONObject.Create;
  Event.Add('protocolVersion', Int64(1));
  Event.Add('id', AId);
  Event.Add('type', 'ready');
  Event.Add('language', 'delphi-object-pascal');
  Event.Add('implementation', 'native');
  Event.Add('runtime', RuntimeVersion);
  WriteEvent(Event);
end;

procedure SendResult(const AId: string; AValue: TJSONData; ALogs: TStrings);
var
  Event: TJSONObject;
begin
  Event := TJSONObject.Create;
  Event.Add('id', AId);
  Event.Add('type', 'result');
  Event.Add('value', AValue.Clone);
  Event.Add('logs', LogsValue(ALogs));
  WriteEvent(Event);
end;

function ErrorEvent(AId: TJSONData; const AMessage, AName: string; AData: TJSONData): TJSONObject;
var
  ErrorObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  if AId <> nil then
    Result.Add('id', AId);
  Result.Add('type', 'error');
  ErrorObject := TJSONObject.Create;
  ErrorObject.Add('name', AName);
  ErrorObject.Add('message', AMessage);
  if AData <> nil then
    ErrorObject.Add('data', AData.Clone)
  else
    ErrorObject.Add('data', TJSONNull.Create);
  Result.Add('error', ErrorObject);
end;

procedure SendCallError(const AId: string; const AMessage: string; AData: TJSONData);
begin
  WriteEvent(ErrorEvent(StringValue(AId), AMessage, 'Error', AData));
end;

procedure SendProtocolError(const AId: string; const AMessage: string);
begin
  if AId = '' then
    WriteEvent(ErrorEvent(nil, AMessage, 'ProtocolError', nil))
  else
    WriteEvent(ErrorEvent(StringValue(AId), AMessage, 'ProtocolError', nil));
end;

procedure SendTransportError(const AId: string; const AMessage: string);
begin
  WriteEvent(ErrorEvent(StringValue(AId), AMessage, 'TransportError', nil));
end;

procedure SendAck(const AId: string);
var
  Event: TJSONObject;
begin
  Event := TJSONObject.Create;
  Event.Add('id', AId);
  Event.Add('type', 'ack');
  WriteEvent(Event);
end;

procedure SendClosed(const AId: string);
var
  Event: TJSONObject;
begin
  Event := TJSONObject.Create;
  Event.Add('id', AId);
  Event.Add('type', 'closed');
  WriteEvent(Event);
end;

procedure SendSubscriptionValue(const ASubscriptionId: string; AValue: TJSONData);
var
  Event: TJSONObject;
  EmptyLogs: TStrings;
begin
  Event := TJSONObject.Create;
  Event.Add('type', 'subscription');
  Event.Add('subscriptionId', ASubscriptionId);
  Event.Add('value', AValue.Clone);
  EmptyLogs := TStringList.Create;
  Event.Add('logs', LogsValue(EmptyLogs));
  EmptyLogs.Free;
  WriteEvent(Event);
end;

procedure SendSubscriptionError(const ASubscriptionId: string; const AMessage: string; AData: TJSONData);
var
  Event, ErrorObject: TJSONObject;
begin
  Event := TJSONObject.Create;
  Event.Add('type', 'subscription');
  Event.Add('subscriptionId', ASubscriptionId);
  ErrorObject := TJSONObject.Create;
  ErrorObject.Add('name', 'Error');
  ErrorObject.Add('message', AMessage);
  if AData <> nil then
    ErrorObject.Add('data', AData.Clone)
  else
    ErrorObject.Add('data', TJSONNull.Create);
  Event.Add('error', ErrorObject);
  WriteEvent(Event);
end;

// -- Command handlers -----------------------------------------------------

procedure HandleHello(ACommand: TJSONData; const AId: string);
var
  VersionField: TJSONData;
begin
  if HasField(ACommand, 'protocolVersion') then
  begin
    VersionField := TJSONObject(ACommand).Find('protocolVersion');
    if IsIntegralNumberInRange(VersionField, 1, 1) then
    begin
      SendReady(AId);
      Exit;
    end;
  end;
  SendProtocolError(AId, 'unsupported protocol version');
end;

procedure HandleCall(const AOp: string; ACommand: TJSONData; const AId: string);
var
  Path: string;
  Args: TJSONData;
  CallResult: TConvexResult;
  HavePath, HaveArgs: Boolean;
begin
  HavePath := StringField(ACommand, 'path', Path);
  HaveArgs := ObjectField(ACommand, 'args', Args);
  if not HavePath or not HaveArgs or not GClient.IsModuleColonFunction(Path) then
  begin
    SendProtocolError(AId, 'invalid call request');
    Exit;
  end;
  if AOp = 'query' then
    CallResult := GClient.Query(Path, Args)
  else if AOp = 'mutation' then
    CallResult := GClient.Mutation(Path, Args)
  else
    CallResult := GClient.Action(Path, Args);
  if CallResult = nil then
    SendTransportError(AId, GClient.LastError)
  else
  begin
    try
      if CallResult.IsSuccess then
        SendResult(AId, CallResult.Value, CallResult.Logs)
      else
        SendCallError(AId, CallResult.ErrorMessage, CallResult.ErrorData);
    finally
      CallResult.Free;
    end;
  end;
end;

procedure HandleSubscribe(ACommand: TJSONData; const AId: string);
var
  SubscriptionId, Path: string;
  Args: TJSONData;
begin
  if not StringField(ACommand, 'subscriptionId', SubscriptionId)
    or not StringField(ACommand, 'path', Path)
    or not ObjectField(ACommand, 'args', Args) then
  begin
    SendProtocolError(AId, 'invalid subscribe request');
    Exit;
  end;
  GLiveCreated := True;
  MaybeEnsureLiveConnected;
  if GClient.Live.IsSubscribed(SubscriptionId) then
  begin
    SendProtocolError(AId, 'duplicate subscriptionId');
    Exit;
  end;
  GClient.Live.AddSubscription(SubscriptionId, Path, Args);
  SendAck(AId);
end;

procedure HandleUnsubscribe(ACommand: TJSONData; const AId: string);
var
  SubscriptionId: string;
begin
  if not StringField(ACommand, 'subscriptionId', SubscriptionId)
    or not GLiveCreated or not GClient.Live.IsSubscribed(SubscriptionId) then
  begin
    SendProtocolError(AId, 'unknown subscriptionId');
    Exit;
  end;
  GClient.Live.RemoveSubscription(SubscriptionId);
  SendAck(AId);
end;

procedure HandleSetAuth(ACommand: TJSONData; const AId: string);
var
  Token: string;
begin
  if not StringField(ACommand, 'token', Token) then
    Token := '';
  GClient.SetAuth(Token);
  SendAck(AId);
end;

procedure HandleDebugDisconnect(const AId: string);
begin
  if GLiveCreated then
    GClient.Live.ForceDisconnect;
  SendAck(AId);
end;

procedure HandleClose(const AId: string);
begin
  SendClosed(AId);
  GClosed := True;
end;

procedure HandleLine(const ALine: string);
var
  Command: TJSONData;
  Op, Id: string;
  HaveOp, HaveId: Boolean;
begin
  try
    Command := GetJSON(ALine);
  except
    on E: Exception do
    begin
      SendProtocolError('', 'malformed request');
      Exit;
    end;
  end;
  try
    if Command.JSONType <> jtObject then
    begin
      SendProtocolError('', 'malformed request');
      Exit;
    end;
    HaveOp := StringField(Command, 'op', Op);
    HaveId := StringField(Command, 'id', Id);
    if not HaveOp then
      SendProtocolError('', 'missing op')
    else if not HaveId or (Id = '') or (Length(Id) > 128) then
      SendProtocolError('', 'id must contain 1 to 128 Unicode characters')
    else if Op = 'hello' then
      HandleHello(Command, Id)
    else if (Op = 'query') or (Op = 'mutation') or (Op = 'action') then
      HandleCall(Op, Command, Id)
    else if Op = 'subscribe' then
      HandleSubscribe(Command, Id)
    else if Op = 'unsubscribe' then
      HandleUnsubscribe(Command, Id)
    else if Op = 'setAuth' then
      HandleSetAuth(Command, Id)
    else if Op = 'debugDisconnect' then
      HandleDebugDisconnect(Id)
    else if Op = 'close' then
      HandleClose(Id)
    else
      SendProtocolError(Id, 'unknown operation: ' + Op);
  finally
    Command.Free;
  end;
end;

// -- Main loop -----------------------------------------------------

procedure DrainLiveEvents;
var
  I: Integer;
  Event: TConvexSyncEvent;
begin
  for I := 0 to GClient.Live.PendingEvents.Count - 1 do
  begin
    Event := GClient.Live.PendingEvents[I];
    if Event.IsError then
      SendSubscriptionError(Event.SubscriptionId, Event.ErrorMessage, Event.ErrorData)
    else
      SendSubscriptionValue(Event.SubscriptionId, Event.Value);
  end;
  GClient.Live.PendingEvents.Clear;
end;

procedure RunLoop;
var
  Readiness: Integer;
  LiveFd: cint;
  Line: string;
begin
  while not GClosed do
  begin
    MaybeEnsureLiveConnected;
    LiveFd := -1;
    if LiveOpen then
      LiveFd := GClient.Live.Descriptor;

    if GControl.HasBufferedLine or (LiveOpen and GClient.Live.HasPendingBytes) then
      Readiness := 3
    else
      Readiness := WaitReadableTwo(GControl.Descriptor, LiveFd, PollIntervalMs);

    if ((Readiness and 1) <> 0) or GControl.HasBufferedLine then
      if GControl.ReadLine(0, Line) then
        HandleLine(Line);

    if LiveOpen and (((Readiness and 2) <> 0) or GClient.Live.HasPendingBytes) then
    begin
      GClient.Live.Poll(0);
      DrainLiveEvents;
    end;
  end;
end;

// -- Entry point -----------------------------------------------------

var
  DeploymentUrl: string;
  ListenSpec: string;
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
  ListenSpec := GetEnvironmentVariable('ADAPTER_LISTEN');
  if ListenSpec = '' then
    GControl := TConvexControlStream.CreateStdio
  else
    GControl := TConvexControlStream.CreateListening(ListenSpec);

  if DeploymentUrl = '' then
  begin
    WriteLn(StdErr, 'CONVEX_URL is required');
    Halt(1);
  end;

  GClient := TConvexClient.Create(DeploymentUrl);
  try
    if GControl.IsReady then
      RunLoop;
  finally
    GClient.Free;
    GControl.Free;
  end;
end.
