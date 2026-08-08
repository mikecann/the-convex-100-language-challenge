{ Small helpers layered on Free Pascal's bundled fpjson unit (fcl-json),
  used instead of a hand-written JSON parser: fpjson already gives Delphi
  mode a proper TJSONObject/TJSONArray value tree with `GetJSON` for
  decoding, so this unit only adds the one thing it does not: recognising
  that Convex's documented JSON format may render a whole number as
  "0.0" rather than "0", so callers that expect an integer must check the
  value is actually integral and in range instead of truncating a
  fractional or out-of-range number silently. }
unit ConvexJsonUtil;

{$mode delphi}

interface

uses
  fpjson, SysUtils, Math;

// Is `Data' a JSON number that is mathematically integral (no fractional
// part) and within [Low, High]?
function IsIntegralNumberInRange(Data: TJSONData; Low, High: Int64): Boolean;

// `Data' truncated to an Int64. Call only after IsIntegralNumberInRange
// has confirmed the value is safe.
function DecodedInteger(Data: TJSONData): Int64;

// The field named `FieldName' of JSON object `Obj', raising an
// EConvexJson exception (rather than returning a misleading default) if
// `Obj' is not an object or has no such field.
function RequiredField(Obj: TJSONData; const FieldName: string): TJSONData;

// Does JSON object `Obj' carry a field named `FieldName'?
function HasField(Obj: TJSONData; const FieldName: string): Boolean;

type
  EConvexJson = class(Exception);

implementation

function IsIntegralNumberInRange(Data: TJSONData; Low, High: Int64): Boolean;
var
  Value: Double;
begin
  Result := False;
  if (Data = nil) or (Data.JSONType <> jtNumber) then
    Exit;
  Value := Data.AsFloat;
  if IsNan(Value) or IsInfinite(Value) then
    Exit;
  Result := (Value = Trunc(Value)) and (Value >= Low) and (Value <= High);
end;

function DecodedInteger(Data: TJSONData): Int64;
begin
  Result := Trunc(Data.AsFloat);
end;

function HasField(Obj: TJSONData; const FieldName: string): Boolean;
begin
  Result := (Obj <> nil) and (Obj.JSONType = jtObject)
    and (TJSONObject(Obj).Find(FieldName) <> nil);
end;

function RequiredField(Obj: TJSONData; const FieldName: string): TJSONData;
begin
  if (Obj = nil) or (Obj.JSONType <> jtObject) then
    raise EConvexJson.CreateFmt('expected a JSON object, looking for "%s"', [FieldName]);
  Result := TJSONObject(Obj).Find(FieldName);
  if Result = nil then
    raise EConvexJson.CreateFmt('missing JSON field "%s"', [FieldName]);
end;

initialization
  // fpjson's TJSONData.AsJSON defaults to inserting a space after every
  // `:' and `,' (CompressedJSON = False). Every wire format this project
  // emits, NDJSON adapter events, HTTP request bodies, and outgoing Live
  // frames, is expected to be ordinary compact JSON, and the shared
  // conformance byte budget charges every byte on the wire. This class
  // property is process-global, so setting it once here, in the one unit
  // every other Convex unit already uses, is enough to make every AsJSON
  // call in this client compact without repeating the assignment in each
  // program's initialization.
  TJSONData.CompressedJSON := True;

  // fpc's `string' is AnsiString, tagged with whatever DefaultSystemCodePage
  // happens to be. On a minimal Linux container with no locale installed
  // that defaults to a codepage with no real conversion table, so any
  // WideString-to-AnsiString conversion silently replaces every character
  // outside plain ASCII with `?'. jsonscanner.pp's own `\uXXXX' escape
  // decoder takes the correct UTF-8 path only "if (joUTF8 in Options) or
  // (DefaultSystemCodePage=CP_UTF8)", and every other WideChar/AnsiString
  // conversion in the RTL (including the one behind Convex request bodies
  // and adapter output) consults the very same global. Setting it once
  // here, before any string touches JSON or the wire, makes AnsiString
  // mean UTF-8 everywhere in this client, which is what Convex's JSON
  // protocol actually requires.
  DefaultSystemCodePage := CP_UTF8;

end.
