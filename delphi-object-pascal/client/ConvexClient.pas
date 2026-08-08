{ A native Object Pascal (Delphi mode) client for Convex's documented public
  HTTP API and the pinned `convex-rs-0.10.4-unversioned-sync' Live profile
  (see docs/protocol-profiles.md and docs/conformance.md in the repository
  root). Query, Mutation, and Action always go over HTTP; Subscribe opens
  (or reuses) one WebSocket connection carrying only query-set add/remove
  and reactive updates, never mutations, matching the same scope this
  project's other Live-capable clients document.

  This is the one unit the educational example imports: everything else
  under client/ (ConvexSocket, ConvexWebSocket, ConvexSync, ...) is
  transport plumbing this class assembles, in the same spirit as a real
  Delphi library exposing one TObject-based facade over several
  collaborating units. }
unit ConvexClient;

{$mode delphi}

interface

uses
  SysUtils, fpjson, jsonparser,
  ConvexHttpClient, ConvexResult, ConvexSync, ConvexJsonUtil;

type
  EConvexClient = class(Exception);

  TConvexClient = class
  private
    FHost: string;
    FPort: Word;
    FUseTls: Boolean;
    FHttp: TConvexHttpClient;
    FAuthToken: string;
    FSync: TConvexSync;
    FLastError: string;

    procedure ParseUrl(const AUrl: string);
    function CallHttp(const AOp, APath: string; AArgs: TJSONData): TConvexResult;
  public
    // Configure this client for the Convex deployment at ADeploymentUrl
    // (for example "https://happy-otter-123.convex.cloud" or
    // "http://127.0.0.1:3210" for a local deployment). No network
    // connection is opened yet. Raises EConvexClient if the URL is not
    // well formed.
    constructor Create(const ADeploymentUrl: string);
    destructor Destroy; override;

    // A short diagnostic for the most recent transport-level failure.
    // Application errors are reported through TConvexResult instead,
    // since a thrown ConvexError is not a client failure.
    property LastError: string read FLastError;

    // Send AToken as `Authorization: Bearer <token>' on every later HTTP
    // call, or clear it when AToken is empty. Also updates any open Live
    // connection so a later reconnect carries the same identity.
    procedure SetAuth(const AToken: string);

    // Run the query/mutation/action at APath with AArgs over HTTP. nil
    // (with LastError set) only on a transport failure; an
    // application-level failure still returns a TConvexResult with
    // IsSuccess False. The caller owns the returned TConvexResult and
    // must free it.
    function Query(const APath: string; AArgs: TJSONData): TConvexResult;
    function Mutation(const APath: string; AArgs: TJSONData): TConvexResult;
    function Action(const APath: string; AArgs: TJSONData): TConvexResult;

    // The lazily created sync connection backing Subscribe-style calls.
    // Exposed directly so the conformance adapter can also reach
    // ForceDisconnect and PendingEvents.
    function Live: TConvexSync;

    function UrlIsWellFormed(const AUrl: string): Boolean;
    // Does APath look like Convex's `module:function' function
    // reference, with a non-empty name on each side of the colon?
    function IsModuleColonFunction(const APath: string): Boolean;
  end;

implementation

constructor TConvexClient.Create(const ADeploymentUrl: string);
begin
  inherited Create;
  if not UrlIsWellFormed(ADeploymentUrl) then
    raise EConvexClient.CreateFmt('not a well-formed deployment URL: %s', [ADeploymentUrl]);
  ParseUrl(ADeploymentUrl);
  FHttp := TConvexHttpClient.Create(ADeploymentUrl);
end;

destructor TConvexClient.Destroy;
begin
  FSync.Free;
  FHttp.Free;
  inherited Destroy;
end;

procedure TConvexClient.SetAuth(const AToken: string);
begin
  FAuthToken := AToken;
end;

function TConvexClient.Query(const APath: string; AArgs: TJSONData): TConvexResult;
begin
  if not IsModuleColonFunction(APath) then
    raise EConvexClient.CreateFmt('not a module:function path: %s', [APath]);
  Result := CallHttp('query', APath, AArgs);
end;

function TConvexClient.Mutation(const APath: string; AArgs: TJSONData): TConvexResult;
begin
  if not IsModuleColonFunction(APath) then
    raise EConvexClient.CreateFmt('not a module:function path: %s', [APath]);
  Result := CallHttp('mutation', APath, AArgs);
end;

function TConvexClient.Action(const APath: string; AArgs: TJSONData): TConvexResult;
begin
  if not IsModuleColonFunction(APath) then
    raise EConvexClient.CreateFmt('not a module:function path: %s', [APath]);
  Result := CallHttp('action', APath, AArgs);
end;

function TConvexClient.Live: TConvexSync;
begin
  if FSync = nil then
    FSync := TConvexSync.Create(FHost, FPort, FUseTls);
  Result := FSync;
end;

function TConvexClient.CallHttp(const AOp, APath: string; AArgs: TJSONData): TConvexResult;
var
  TransportError: string;
begin
  Result := FHttp.Call(AOp, APath, AArgs, FAuthToken, TransportError);
  if Result = nil then
    FLastError := 'transport: ' + TransportError;
end;

function TConvexClient.UrlIsWellFormed(const AUrl: string): Boolean;
begin
  Result := ((Pos('https://', AUrl) = 1) and (Length(AUrl) > 8))
    or ((Pos('http://', AUrl) = 1) and (Length(AUrl) > 7));
end;

function TConvexClient.IsModuleColonFunction(const APath: string): Boolean;
var
  ColonIndex: Integer;
begin
  ColonIndex := Pos(':', APath);
  Result := (ColonIndex > 1) and (ColonIndex < Length(APath));
end;

procedure TConvexClient.ParseUrl(const AUrl: string);
var
  AfterScheme: string;
  ColonIndex, HostEnd: Integer;
begin
  if Pos('https://', AUrl) = 1 then
  begin
    FUseTls := True;
    AfterScheme := Copy(AUrl, 9, Length(AUrl) - 8);
    FPort := 443;
  end
  else
  begin
    FUseTls := False;
    AfterScheme := Copy(AUrl, 8, Length(AUrl) - 7);
    FPort := 80;
  end;
  HostEnd := Pos('/', AfterScheme);
  if HostEnd = 0 then
    HostEnd := Length(AfterScheme) + 1;
  AfterScheme := Copy(AfterScheme, 1, HostEnd - 1);
  ColonIndex := Pos(':', AfterScheme);
  if ColonIndex > 0 then
  begin
    FHost := Copy(AfterScheme, 1, ColonIndex - 1);
    FPort := StrToInt(Copy(AfterScheme, ColonIndex + 1, Length(AfterScheme) - ColonIndex));
  end
  else
    FHost := AfterScheme;
end;

end.
