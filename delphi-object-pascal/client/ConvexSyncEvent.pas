{ One reactive update for a Live subscription, decoded from a `QueryUpdated'
  or `QueryFailed' sync-protocol modification and carrying the adapter
  subscription id it belongs to. Owns Value/ErrorData (always an
  independent Clone, never a node still attached to some other object's
  tree) and frees them when freed itself. }
unit ConvexSyncEvent;

{$mode delphi}

interface

uses
  fpjson;

type
  TConvexSyncEvent = class
  private
    FSubscriptionId: string;
    FIsError: Boolean;
    FValue: TJSONData;
    FErrorMessage: string;
    FErrorData: TJSONData;
  public
    constructor CreateValue(const ASubscriptionId: string; AValue: TJSONData);
    constructor CreateError(const ASubscriptionId: string; const AMessage: string; AErrorData: TJSONData);
    destructor Destroy; override;

    property SubscriptionId: string read FSubscriptionId;
    property IsError: Boolean read FIsError;
    // The updated query result. Only meaningful when not IsError.
    property Value: TJSONData read FValue;
    // The reactive query's failure message. Only meaningful when IsError.
    property ErrorMessage: string read FErrorMessage;
    // The thrown ConvexError's structured payload, if any. May be nil
    // even when IsError (an ordinary, non-ConvexError failure).
    property ErrorData: TJSONData read FErrorData;
  end;

implementation

constructor TConvexSyncEvent.CreateValue(const ASubscriptionId: string; AValue: TJSONData);
begin
  inherited Create;
  FSubscriptionId := ASubscriptionId;
  FIsError := False;
  FValue := AValue;
end;

constructor TConvexSyncEvent.CreateError(const ASubscriptionId: string; const AMessage: string; AErrorData: TJSONData);
begin
  inherited Create;
  FSubscriptionId := ASubscriptionId;
  FIsError := True;
  FErrorMessage := AMessage;
  FErrorData := AErrorData;
end;

destructor TConvexSyncEvent.Destroy;
begin
  FValue.Free;
  FErrorData.Free;
  inherited Destroy;
end;

end.
