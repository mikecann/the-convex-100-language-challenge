{ Language-local unit tests for the Delphi-specific logic layered over
  Free Pascal's bundled fpjson and fphttpclient units, run with no network
  access as part of the Docker `test' image. fpjson and fphttpclient
  themselves are an established, separately tested dependency (see the
  client README); what this project adds on top -- Convex's
  integral-number-in-range decoding rule, deployment URL parsing, and the
  `module:function' path convention -- is what needs its own regression
  coverage here. ConvexSocket, ConvexWebSocket, ConvexSync, and
  ConvexClient's actual network paths were validated end to end against a
  running local Convex backend and a real TLS host during development;
  that network-dependent proof is what `./run verify-example' and `./run
  verify' repeat and check automatically. }
program ConvexClientTests;

{$mode delphi}
{$apptype console}

uses
  SysUtils, fpjson, jsonparser,
  ConvexJsonUtil, ConvexClient;

var
  FailureCount: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if not ACondition then
  begin
    WriteLn(StdErr, 'FAILED: ', AName);
    Inc(FailureCount);
  end;
end;

// Convex's JSON transport may render an integral value as "0.0"/"1.0";
// callers must accept that form and still reject fractional or
// out-of-range values rather than truncating them silently. This is the
// specific regression AGENTS.md calls out for decoding, not a fixture
// only exercising integer literals.
procedure CheckIntegralRangeAcceptance;
var
  Zero, Fraction, TooBig, Text: TJSONData;
begin
  Zero := GetJSON('0.0');
  try
    Check(IsIntegralNumberInRange(Zero, 0, 10), 'zero is integral in [0,10]');
    Check(DecodedInteger(Zero) = 0, 'zero decodes to 0');
  finally
    Zero.Free;
  end;

  Fraction := GetJSON('2.5');
  try
    Check(not IsIntegralNumberInRange(Fraction, 0, 10), 'fraction is rejected');
  finally
    Fraction.Free;
  end;

  TooBig := GetJSON('1000000000000');
  try
    Check(not IsIntegralNumberInRange(TooBig, 0, 1000), 'out of range value is rejected');
  finally
    TooBig.Free;
  end;

  Text := GetJSON('"3"');
  try
    Check(not IsIntegralNumberInRange(Text, 0, 10), 'a quoted number is not a JSON number');
  finally
    Text.Free;
  end;
end;

// HasField/RequiredField look a field up by name (content), not by any
// accidental object identity, and RequiredField raises rather than
// returning a misleading default when the field or the shape is wrong.
procedure CheckFieldLookup;
var
  Obj: TJSONData;
  Raised: Boolean;
begin
  Obj := GetJSON('{"count":0,"nested":{"a":1}}');
  try
    Check(HasField(Obj, 'count'), 'HasField finds a present field');
    Check(not HasField(Obj, 'missing'), 'HasField rejects an absent field');
    Check(RequiredField(Obj, 'nested').JSONType = jtObject, 'RequiredField returns the right node');

    Raised := False;
    try
      RequiredField(Obj, 'missing');
    except
      on E: EConvexJson do
        Raised := True;
    end;
    Check(Raised, 'RequiredField raises for an absent field');
  finally
    Obj.Free;
  end;
end;

// A well-formed https:// or http:// deployment URL is accepted; anything
// else -- including a scheme-less host, which would otherwise silently
// default to some scheme -- is rejected up front rather than surfacing
// as a confusing transport failure later.
procedure CheckUrlWellFormedness;
var
  Client: TConvexClient;
  Raised: Boolean;
begin
  Client := TConvexClient.Create('http://127.0.0.1:3210');
  try
    Check(Client.UrlIsWellFormed('https://happy-otter-123.convex.cloud'), 'https URL is well formed');
    Check(Client.UrlIsWellFormed('http://127.0.0.1:3210'), 'http URL with a port is well formed');
    Check(not Client.UrlIsWellFormed('127.0.0.1:3210'), 'a scheme-less host is rejected');
    Check(not Client.UrlIsWellFormed('ftp://example.com'), 'a non-HTTP scheme is rejected');
    Check(not Client.UrlIsWellFormed('https://'), 'a scheme with no host is rejected');
  finally
    Client.Free;
  end;

  Raised := False;
  try
    Client := TConvexClient.Create('not-a-url');
    Client.Free;
  except
    on E: EConvexClient do
      Raised := True;
  end;
  Check(Raised, 'constructing with a malformed URL raises EConvexClient');
end;

// Convex's public HTTP API requires a `module:function' path shape; a
// bare name or an empty side of the colon must be rejected before ever
// reaching the network.
procedure CheckModuleColonFunction;
var
  Client: TConvexClient;
begin
  Client := TConvexClient.Create('http://127.0.0.1:3210');
  try
    Check(Client.IsModuleColonFunction('demo:state'), 'module:function is accepted');
    Check(not Client.IsModuleColonFunction('demo'), 'a bare name is rejected');
    Check(not Client.IsModuleColonFunction(':state'), 'an empty module name is rejected');
    Check(not Client.IsModuleColonFunction('demo:'), 'an empty function name is rejected');
    Check(not Client.IsModuleColonFunction(''), 'an empty path is rejected');
  finally
    Client.Free;
  end;
end;

begin
  FailureCount := 0;
  CheckIntegralRangeAcceptance;
  CheckFieldLookup;
  CheckUrlWellFormedness;
  CheckModuleColonFunction;
  if FailureCount > 0 then
  begin
    WriteLn(StdErr, IntToStr(FailureCount), ' check(s) failed');
    Halt(1);
  end;
  WriteLn('ALL_TESTS_PASSED');
end.
