{ The client side of the pinned `convex-rs-0.10.4-unversioned-sync' realtime
  profile (see docs/protocol-profiles.md in the repository root): one
  WebSocket connection to `/api/sync' carrying `Connect' and
  `ModifyQuerySet' client messages and `Transition' server messages.
  Mutations and actions are deliberately never sent over this connection;
  TConvexClient always runs those over HTTP, the same choice this project's
  other Live-capable clients already document.

  This class owns the socket exclusively: the adapter's single I/O owner is
  expected to call Poll only after learning (through select, watching
  Descriptor alongside its control stream) that a message may be waiting,
  and to call EnsureConnected whenever it notices IsConnected has gone
  False. No other thread or subscription touches the connection directly,
  which is what makes the reconnect and unsubscribe bookkeeping below safe
  without locks. }
unit ConvexSync;

{$mode delphi}

interface

uses
  SysUtils, Generics.Collections, fpjson, jsonparser,
  ConvexWebSocket, ConvexSyncEvent, ConvexJsonUtil;

type
  TConvexSync = class
  private
    FHost: string;
    FPort: Word;
    FUseTls: Boolean;
    FConnection: TConvexWebSocket;
    FSessionId: string;
    FConnectionCount: Integer;
    FQuerySetVersion: Integer;
    FNextQueryId: Integer;
    FLastCloseReason: string;
    FLastError: string;

    FSubscriptionToQuery: TDictionary<string, Integer>;
    FQueryToSubscription: TDictionary<Integer, string>;
    FQueryPath: TDictionary<Integer, string>;
    FQueryArgs: TObjectDictionary<Integer, TJSONData>;
    FLastSignature: TDictionary<Integer, string>;
    FPendingEvents: TObjectList<TConvexSyncEvent>;

    function FreshSessionId: string;
    function BuildAddModification(AQueryId: Integer; const APath: string; AArgs: TJSONData): TJSONObject;
    function BuildRemoveModification(AQueryId: Integer): TJSONObject;
    function SendConnectMessage: Boolean;
    // Takes ownership of AModifications (always frees it, even on failure).
    function SendModifyQuerySet(AModifications: TJSONArray): Boolean;
    procedure RebuildQuerySet;
    procedure HandleServerMessage(AMessage: TJSONData);
    procedure HandleTransition(AMessage: TJSONData);
    procedure DispatchModification(const AKind: string; AQueryId: Integer; AModification: TJSONData);
    // Has AQueryId already reported exactly ASignature? Records
    // ASignature as the new last-known state either way.
    function SignatureUnchanged(AQueryId: Integer; const ASignature: string): Boolean;
  public
    // Configure (without yet connecting to) the sync endpoint at
    // AHost:APort. Call EnsureConnected to open it.
    constructor Create(const AHost: string; APort: Word; AUseTls: Boolean);
    destructor Destroy; override;

    function IsConnected: Boolean;
    property LastError: string read FLastError;
    // The active connection's file descriptor, for the adapter's outer
    // select. Only meaningful when IsConnected.
    function Descriptor: THandle;
    // Does the transport already hold bytes a select loop must drain
    // before waiting on Descriptor again?
    function HasPendingBytes: Boolean;
    function IsSubscribed(const ASubscriptionId: string): Boolean;
    // Events produced by Poll since the caller last drained this list.
    // The caller empties it (via Clear, which frees the drained events)
    // after reading.
    property PendingEvents: TObjectList<TConvexSyncEvent> read FPendingEvents;

    // Open the connection if it is not already open, replaying every
    // currently active subscription as one ModifyQuerySet so the server
    // rebuilds exactly the query set the caller believes is active.
    // Idempotent when already connected.
    procedure EnsureConnected;
    // Test-only fault injection for the adapter's debugDisconnect
    // command: sever the transport immediately so the next
    // EnsureConnected call performs a real reconnect. Safe to call
    // whether or not a connection is currently open.
    procedure ForceDisconnect;

    // Start a reactive query for APath with AArgs, routing its future
    // updates to ASubscriptionId. False (with LastError set) if the
    // request could not be sent; the caller should still treat the
    // subscription as pending and rely on the next EnsureConnected to
    // establish it.
    function AddSubscription(const ASubscriptionId, APath: string; AArgs: TJSONData): Boolean;
    // Stop the reactive query behind ASubscriptionId.
    function RemoveSubscription(const ASubscriptionId: string): Boolean;

    // Receive and process at most one sync message, appending any
    // resulting subscription updates to PendingEvents. A closed or
    // failed connection here is not reported as an error: it simply
    // leaves IsConnected False for the caller's next EnsureConnected to
    // repair.
    procedure Poll(ATimeoutMs: Integer);
  end;

implementation

const
  SyncPath = '/api/sync';

constructor TConvexSync.Create(const AHost: string; APort: Word; AUseTls: Boolean);
begin
  inherited Create;
  FHost := AHost;
  FPort := APort;
  FUseTls := AUseTls;
  FSessionId := FreshSessionId;
  FConnectionCount := 0;
  FNextQueryId := 1;
  FSubscriptionToQuery := TDictionary<string, Integer>.Create;
  FQueryToSubscription := TDictionary<Integer, string>.Create;
  FQueryPath := TDictionary<Integer, string>.Create;
  FQueryArgs := TObjectDictionary<Integer, TJSONData>.Create([doOwnsValues]);
  FLastSignature := TDictionary<Integer, string>.Create;
  FPendingEvents := TObjectList<TConvexSyncEvent>.Create(True);
  FLastCloseReason := 'InitialConnect';
end;

destructor TConvexSync.Destroy;
begin
  if FConnection <> nil then
    FConnection.Close('shutdown');
  FConnection.Free;
  FSubscriptionToQuery.Free;
  FQueryToSubscription.Free;
  FQueryPath.Free;
  FQueryArgs.Free;
  FLastSignature.Free;
  FPendingEvents.Free;
  inherited Destroy;
end;

function TConvexSync.IsConnected: Boolean;
begin
  Result := (FConnection <> nil) and FConnection.IsOpen;
end;

function TConvexSync.Descriptor: THandle;
begin
  Result := FConnection.Descriptor;
end;

function TConvexSync.HasPendingBytes: Boolean;
begin
  Result := (FConnection <> nil) and FConnection.HasPendingBytes;
end;

function TConvexSync.IsSubscribed(const ASubscriptionId: string): Boolean;
begin
  Result := FSubscriptionToQuery.ContainsKey(ASubscriptionId);
end;

procedure TConvexSync.EnsureConnected;
var
  NewConnection: TConvexWebSocket;
begin
  if IsConnected then
    Exit;
  Inc(FConnectionCount);
  NewConnection := TConvexWebSocket.Create(FHost, FPort, SyncPath, FUseTls);
  if not NewConnection.IsOpen then
  begin
    FLastError := NewConnection.LastError;
    NewConnection.Free;
    Exit;
  end;
  FConnection := NewConnection;
  FQuerySetVersion := 0;
  if SendConnectMessage then
    RebuildQuerySet;
end;

procedure TConvexSync.ForceDisconnect;
begin
  if FConnection <> nil then
    FConnection.Close('debugDisconnect');
  FreeAndNil(FConnection);
  FLastCloseReason := 'debugDisconnect';
end;

function TConvexSync.AddSubscription(const ASubscriptionId, APath: string; AArgs: TJSONData): Boolean;
var
  QueryId: Integer;
  Mods: TJSONArray;
begin
  QueryId := FNextQueryId;
  Inc(FNextQueryId);
  FSubscriptionToQuery.Add(ASubscriptionId, QueryId);
  FQueryToSubscription.Add(QueryId, ASubscriptionId);
  FQueryPath.Add(QueryId, APath);
  FQueryArgs.Add(QueryId, AArgs.Clone);
  if IsConnected then
  begin
    Mods := TJSONArray.Create;
    Mods.Add(BuildAddModification(QueryId, APath, AArgs));
    Result := SendModifyQuerySet(Mods);
  end
  else
    Result := True;
end;

function TConvexSync.RemoveSubscription(const ASubscriptionId: string): Boolean;
var
  QueryId: Integer;
  Mods: TJSONArray;
begin
  QueryId := FSubscriptionToQuery[ASubscriptionId];
  if IsConnected then
  begin
    Mods := TJSONArray.Create;
    Mods.Add(BuildRemoveModification(QueryId));
    Result := SendModifyQuerySet(Mods);
  end
  else
    Result := True;
  FSubscriptionToQuery.Remove(ASubscriptionId);
  FQueryToSubscription.Remove(QueryId);
  FQueryPath.Remove(QueryId);
  FQueryArgs.Remove(QueryId);
  if FLastSignature.ContainsKey(QueryId) then
    FLastSignature.Remove(QueryId);
end;

procedure TConvexSync.Poll(ATimeoutMs: Integer);
var
  Text: string;
  Data: TJSONData;
begin
  if (FConnection = nil) or not FConnection.TryReceiveMessage(ATimeoutMs, Text) then
    Exit;
  try
    Data := GetJSON(Text);
  except
    on E: Exception do
      Exit; // Malformed message from the server; nothing sensible to do.
  end;
  try
    HandleServerMessage(Data);
  finally
    Data.Free;
  end;
end;

function TConvexSync.FreshSessionId: string;
  // A syntactically valid (hyphenated, lowercase hex) UUID-like string.
  // The server only requires this to parse as a UUID; it does not need
  // to come from a cryptographically secure generator.
var
  Guid: TGUID;
begin
  CreateGUID(Guid);
  Result := LowerCase(Copy(GUIDToString(Guid), 2, 36));
end;

function TConvexSync.BuildAddModification(AQueryId: Integer; const APath: string; AArgs: TJSONData): TJSONObject;
  // The sync protocol's `SerializedArgs' is a JSON array holding exactly
  // the one args object Convex functions take.
var
  Wrapper: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'Add');
  Result.Add('queryId', Int64(AQueryId));
  Result.Add('udfPath', APath);
  Wrapper := TJSONArray.Create;
  Wrapper.Add(AArgs.Clone);
  Result.Add('args', Wrapper);
end;

function TConvexSync.BuildRemoveModification(AQueryId: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'Remove');
  Result.Add('queryId', Int64(AQueryId));
end;

function TConvexSync.SendConnectMessage: Boolean;
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create;
  try
    Msg.Add('type', 'Connect');
    Msg.Add('sessionId', FSessionId);
    Msg.Add('connectionCount', Int64(FConnectionCount));
    Msg.Add('lastCloseReason', FLastCloseReason);
    Result := FConnection.SendText(Msg.AsJSON);
  finally
    Msg.Free;
  end;
  if not Result then
    FLastError := FConnection.LastError;
end;

function TConvexSync.SendModifyQuerySet(AModifications: TJSONArray): Boolean;
var
  Msg: TJSONObject;
  BaseVersion: Integer;
begin
  BaseVersion := FQuerySetVersion;
  Inc(FQuerySetVersion);
  Msg := TJSONObject.Create;
  try
    Msg.Add('type', 'ModifyQuerySet');
    Msg.Add('baseVersion', Int64(BaseVersion));
    Msg.Add('newVersion', Int64(FQuerySetVersion));
    Msg.Add('modifications', AModifications);
    Result := FConnection.SendText(Msg.AsJSON);
  finally
    Msg.Free; // Also frees AModifications: TJSONObject.Add transferred ownership.
  end;
  if not Result then
    FLastError := FConnection.LastError;
end;

procedure TConvexSync.RebuildQuerySet;
  // After a fresh connection, resend every still-active subscription as
  // one ModifyQuerySet so the server's query set matches what the
  // caller believes is active. The server has no memory of a previous
  // connection's query set (each connection starts that version counter
  // at zero), so this is not an optimisation: without it, a reconnected
  // client would simply stop receiving updates for its existing
  // subscriptions.
var
  Mods: TJSONArray;
  QueryId: Integer;
begin
  if FQueryPath.Count = 0 then
    Exit;
  Mods := TJSONArray.Create;
  for QueryId in FQueryPath.Keys do
    Mods.Add(BuildAddModification(QueryId, FQueryPath[QueryId], FQueryArgs[QueryId]));
  SendModifyQuerySet(Mods);
end;

procedure TConvexSync.HandleServerMessage(AMessage: TJSONData);
var
  MessageType: string;
begin
  if (AMessage.JSONType = jtObject) and HasField(AMessage, 'type')
    and (TJSONObject(AMessage).Find('type').JSONType = jtString) then
  begin
    MessageType := TJSONObject(AMessage).Find('type').AsString;
    if MessageType = 'Transition' then
      HandleTransition(AMessage)
    else if MessageType = 'FatalError' then
    begin
      FLastError := 'server FatalError';
      if FConnection <> nil then
        FConnection.Close('fatal');
      FreeAndNil(FConnection);
    end;
    // Ping, AuthError, MutationResponse, ActionResponse, and
    // TransitionChunk need no handling: this client never authenticates
    // or mutates over the sync socket, and its test payloads stay far
    // below the size that would trigger chunking (see
    // docs/protocol-profiles.md).
  end;
end;

procedure TConvexSync.HandleTransition(AMessage: TJSONData);
var
  Modifications: TJSONData;
  I: Integer;
  Modification, QueryIdField: TJSONData;
  Kind: string;
  QueryId: Integer;
begin
  if not (HasField(AMessage, 'modifications')
    and (TJSONObject(AMessage).Find('modifications').JSONType = jtArray)) then
    Exit;
  Modifications := TJSONObject(AMessage).Find('modifications');
  for I := 0 to TJSONArray(Modifications).Count - 1 do
  begin
    Modification := TJSONArray(Modifications).Items[I];
    if (Modification.JSONType = jtObject) and HasField(Modification, 'type')
      and (TJSONObject(Modification).Find('type').JSONType = jtString)
      and HasField(Modification, 'queryId') then
    begin
      QueryIdField := TJSONObject(Modification).Find('queryId');
      if IsIntegralNumberInRange(QueryIdField, 0, High(Int32)) then
      begin
        Kind := TJSONObject(Modification).Find('type').AsString;
        QueryId := DecodedInteger(QueryIdField);
        if FQueryToSubscription.ContainsKey(QueryId) then
          DispatchModification(Kind, QueryId, Modification);
      end;
    end;
  end;
end;

procedure TConvexSync.DispatchModification(const AKind: string; AQueryId: Integer; AModification: TJSONData);
  // Reconnecting resends every active query, and the server's reply is
  // an ordinary Transition the same as any other update, even when
  // nothing actually changed. Deliver an event only when the decoded
  // state differs from what this subscription last reported, so a
  // same-value rehydration after debugDisconnect never masquerades as
  // (or delays) a real change: the caller must still see exactly the
  // initial value, then the next genuine update, with nothing stale in
  // between.
var
  SubscriptionId, Signature: string;
  Data: TJSONData;
begin
  SubscriptionId := FQueryToSubscription[AQueryId];
  if (AKind = 'QueryUpdated') and HasField(AModification, 'value') then
  begin
    Signature := 'V:' + TJSONObject(AModification).Find('value').AsJSON;
    if not SignatureUnchanged(AQueryId, Signature) then
      FPendingEvents.Add(TConvexSyncEvent.CreateValue(SubscriptionId, TJSONObject(AModification).Find('value').Clone));
  end
  else if (AKind = 'QueryFailed') and HasField(AModification, 'errorMessage')
    and (TJSONObject(AModification).Find('errorMessage').JSONType = jtString) then
  begin
    Data := nil;
    if HasField(AModification, 'errorData') then
      Data := TJSONObject(AModification).Find('errorData').Clone;
    Signature := 'E:' + TJSONObject(AModification).Find('errorMessage').AsString;
    if not SignatureUnchanged(AQueryId, Signature) then
      FPendingEvents.Add(TConvexSyncEvent.CreateError(
        SubscriptionId, TJSONObject(AModification).Find('errorMessage').AsString, Data))
    else
      Data.Free; // The clone above is otherwise unowned; this event was suppressed.
  end;
  // QueryRemoved needs no event: the adapter already stopped expecting
  // updates once it asked to unsubscribe.
end;

function TConvexSync.SignatureUnchanged(AQueryId: Integer; const ASignature: string): Boolean;
var
  Previous: string;
begin
  Result := FLastSignature.TryGetValue(AQueryId, Previous) and (Previous = ASignature);
  FLastSignature.AddOrSetValue(AQueryId, ASignature);
end;

end.
