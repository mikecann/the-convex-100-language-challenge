{ The outcome of one Convex HTTP call (query, mutation, or action): either
  a decoded success value with any function log lines, or a structured
  failure carrying the server's error message and, for a thrown
  ConvexError, its typed ErrorData.

  A TConvexResult owns its Value/ErrorData (they are always an
  independent Clone of whatever the transport decoded, never a node
  still attached to some other object's tree) and frees them when freed
  itself, so callers never have to reason about who else might hold a
  reference to the same fpjson node. }
unit ConvexResult;

{$mode delphi}

interface

uses
  Classes, SysUtils, fpjson;

type
  TConvexResult = class
  private
    FIsSuccess: Boolean;
    FValue: TJSONData;
    FErrorMessage: string;
    FErrorData: TJSONData;
    FLogs: TStringList;
  public
    constructor CreateSuccess(AValue: TJSONData; ALogs: TStringList);
    constructor CreateFailure(const AMessage: string; AErrorData: TJSONData; ALogs: TStringList);
    destructor Destroy; override;

    property IsSuccess: Boolean read FIsSuccess;
    // The decoded success value. Only meaningful when IsSuccess.
    property Value: TJSONData read FValue;
    // The reactive/HTTP function's failure message. Only meaningful when
    // not IsSuccess.
    property ErrorMessage: string read FErrorMessage;
    // The thrown ConvexError's structured payload, if any. May be nil
    // even when not IsSuccess (an ordinary, non-ConvexError failure).
    property ErrorData: TJSONData read FErrorData;
    // Function log lines, kept distinct from the return value.
    property Logs: TStringList read FLogs;
  end;

implementation

constructor TConvexResult.CreateSuccess(AValue: TJSONData; ALogs: TStringList);
begin
  inherited Create;
  FIsSuccess := True;
  FValue := AValue;
  FLogs := ALogs;
end;

constructor TConvexResult.CreateFailure(const AMessage: string; AErrorData: TJSONData; ALogs: TStringList);
begin
  inherited Create;
  FIsSuccess := False;
  FErrorMessage := AMessage;
  FErrorData := AErrorData;
  FLogs := ALogs;
end;

destructor TConvexResult.Destroy;
begin
  FValue.Free;
  FErrorData.Free;
  FLogs.Free;
  inherited Destroy;
end;

end.
