{ A thin wrapper over Free Pascal's bundled TFPHTTPClient (fcl-web), used
  only to reach Convex's documented public HTTP API
  (`/api/query', `/api/mutation', `/api/action'). TFPHTTPClient already
  implements ordinary HTTP/1.1 request/response framing and, through
  opensslsockets, TLS; this unit's only job is Convex's own request
  envelope, bearer-token header, and response-envelope decoding, which is
  exactly the "normal HTTP, TLS" library allowance every native client in
  this project relies on, not a delegated Convex client. }
unit ConvexHttpClient;

{$mode delphi}

interface

uses
  Classes, SysUtils, fphttpclient, fpjson, jsonparser, opensslsockets,
  ConvexResult, ConvexJsonUtil;

type
  TConvexHttpClient = class
  private
    FBaseUrl: string;
  public
    constructor Create(const ABaseUrl: string);

    // POST `AArgs' (a JSON object) to `/api/<AOp>' at path `APath', with
    // an optional bearer token. Returns the decoded result, or nil (with
    // ALastError set) on a transport failure; an application-level
    // failure still returns a TConvexResult with IsSuccess False.
    function Call(const AOp, APath: string; AArgs: TJSONData;
      const AAuthToken: string; out ALastError: string): TConvexResult;
  end;

implementation

constructor TConvexHttpClient.Create(const ABaseUrl: string);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
end;

function TConvexHttpClient.Call(const AOp, APath: string; AArgs: TJSONData;
  const AAuthToken: string; out ALastError: string): TConvexResult;
var
  Client: TFPHTTPClient;
  Envelope: TJSONObject;
  RequestText, ResponseText: string;
  Response: TJSONData;
  Logs: TStringList;
  I: Integer;
  LogsField, StatusField: TJSONData;
begin
  Result := nil;
  ALastError := '';
  Envelope := TJSONObject.Create;
  try
    Envelope.Add('path', APath);
    Envelope.Add('args', AArgs.Clone);
    Envelope.Add('format', 'json');
    RequestText := Envelope.AsJSON;
  finally
    Envelope.Free;
  end;

  Client := TFPHTTPClient.Create(nil);
  try
    Client.AddHeader('Content-Type', 'application/json');
    if AAuthToken <> '' then
      Client.AddHeader('Authorization', 'Bearer ' + AAuthToken);
    Client.RequestBody := TStringStream.Create(RequestText);
    try
      try
        ResponseText := Client.Post(FBaseUrl + '/api/' + AOp);
      except
        on E: Exception do
        begin
          ALastError := 'transport: ' + E.Message;
          Exit;
        end;
      end;
    finally
      Client.RequestBody.Free;
      Client.RequestBody := nil;
    end;
  finally
    Client.Free;
  end;

  try
    Response := GetJSON(ResponseText);
  except
    on E: Exception do
    begin
      ALastError := 'malformed response JSON: ' + E.Message;
      Exit;
    end;
  end;
  try
    Logs := TStringList.Create;
    if HasField(Response, 'logLines') and (TJSONObject(Response).Find('logLines').JSONType = jtArray) then
    begin
      LogsField := TJSONObject(Response).Find('logLines');
      for I := 0 to TJSONArray(LogsField).Count - 1 do
        if TJSONArray(LogsField).Items[I].JSONType = jtString then
          Logs.Add(TJSONArray(LogsField).Items[I].AsString);
    end;

    StatusField := nil;
    if HasField(Response, 'status') then
      StatusField := TJSONObject(Response).Find('status');
    if (StatusField <> nil) and (StatusField.JSONType = jtString)
      and (StatusField.AsString = 'success') and HasField(Response, 'value') then
    begin
      Result := TConvexResult.CreateSuccess(
        TJSONObject(Response).Find('value').Clone, Logs);
    end
    else if (StatusField <> nil) and (StatusField.JSONType = jtString)
      and (StatusField.AsString = 'error') and HasField(Response, 'errorMessage')
      and (TJSONObject(Response).Find('errorMessage').JSONType = jtString) then
    begin
      if HasField(Response, 'errorData') then
        Result := TConvexResult.CreateFailure(
          TJSONObject(Response).Find('errorMessage').AsString,
          TJSONObject(Response).Find('errorData').Clone, Logs)
      else
        Result := TConvexResult.CreateFailure(
          TJSONObject(Response).Find('errorMessage').AsString, nil, Logs);
    end
    else
    begin
      Logs.Free;
      ALastError := 'unrecognized response shape: ' + ResponseText;
    end;
  finally
    Response.Free;
  end;
end;

end.
