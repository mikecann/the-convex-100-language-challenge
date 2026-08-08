{ The adapter's NDJSON control channel: either the process's own
  stdin/stdout, or (when ADAPTER_LISTEN is set) one accepted TCP
  connection, so the isolated Docker harness can drive the adapter from a
  separate controller container without sharing a pipe. Built directly on
  the RTL's low-level `Sockets'/`BaseUnix' bindings rather than the
  higher-level `ssockets' event-driven server classes, because this only
  ever needs one blocking accept of exactly one connection, not an
  asynchronous accept loop. }
unit ConvexControlStream;

{$mode delphi}

interface

uses
  SysUtils, BaseUnix, Unix, Sockets;

type
  TConvexControlStream = class
  private
    FReadFd: cint;
    FWriteFd: cint;
    FBuffer: AnsiString;
    FIsReady: Boolean;
  public
    // Use the process's own stdin (fd 0) and stdout (fd 1).
    constructor CreateStdio;
    // Listen on ABindSpec ("host:port"), accept exactly one connection,
    // and use it for both reading and writing. Check IsReady afterwards.
    constructor CreateListening(const ABindSpec: string);

    // Did setup succeed? False leaves the adapter nothing to serve.
    property IsReady: Boolean read FIsReady;
    // The readable descriptor, exposed so the adapter's select loop can
    // wait on it alongside any open Live connection.
    function Descriptor: cint;
    // Does a complete NDJSON line already sit in the read buffer, so the
    // next ReadLine would not need to touch the descriptor at all?
    function HasBufferedLine: Boolean;

    // Read one newline-terminated NDJSON command, waiting up to
    // ATimeoutMs for the first new byte if none is already buffered.
    // Returns False on timeout or end of stream.
    function ReadLine(ATimeoutMs: Integer; out ALine: string): Boolean;
    // Write AText followed by a newline.
    function WriteLine(const AText: string): Boolean;
  end;

implementation

constructor TConvexControlStream.CreateStdio;
begin
  inherited Create;
  FReadFd := 0;
  FWriteFd := 1;
  FBuffer := '';
  FIsReady := True;
end;

constructor TConvexControlStream.CreateListening(const ABindSpec: string);
var
  ColonIndex: Integer;
  HostPart: string;
  Port: Word;
  ListenSock, ClientFd: cint;
  Addr: TInetSockAddr;
  AddrLen: tsocklen;
  ReuseOpt: cint;
begin
  inherited Create;
  FBuffer := '';
  ColonIndex := Pos(':', ABindSpec);
  if ColonIndex = 0 then
    Exit;
  HostPart := Copy(ABindSpec, 1, ColonIndex - 1);
  Port := StrToIntDef(Copy(ABindSpec, ColonIndex + 1, Length(ABindSpec) - ColonIndex), 0);
  if Port = 0 then
    Exit;

  ListenSock := fpsocket(AF_INET, SOCK_STREAM, 0);
  if ListenSock < 0 then
    Exit;
  ReuseOpt := 1;
  fpsetsockopt(ListenSock, SOL_SOCKET, SO_REUSEADDR, @ReuseOpt, SizeOf(ReuseOpt));

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(Port);
  if (HostPart = '') or (HostPart = '0.0.0.0') then
    Addr.sin_addr.s_addr := htonl(INADDR_ANY)
  else
    Addr.sin_addr := StrToNetAddr(HostPart);

  if fpbind(ListenSock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    FpClose(ListenSock);
    Exit;
  end;
  if fplisten(ListenSock, 1) <> 0 then
  begin
    FpClose(ListenSock);
    Exit;
  end;

  AddrLen := SizeOf(Addr);
  repeat
    ClientFd := fpaccept(ListenSock, @Addr, @AddrLen);
  until (ClientFd >= 0) or (fpgeterrno <> ESysEINTR);
  FpClose(ListenSock);
  if ClientFd < 0 then
    Exit;

  FReadFd := ClientFd;
  FWriteFd := ClientFd;
  FIsReady := True;
end;

function TConvexControlStream.Descriptor: cint;
begin
  Result := FReadFd;
end;

function TConvexControlStream.HasBufferedLine: Boolean;
begin
  Result := Pos(#10, FBuffer) > 0;
end;

function TConvexControlStream.ReadLine(ATimeoutMs: Integer; out ALine: string): Boolean;
var
  NewlineIndex: Integer;
  ReadSet: TFDSet;
  TimeVal: TTimeVal;
  Rc: cint;
  Buf: array[0..4095] of Byte;
  Got: cint;
begin
  Result := False;
  repeat
    NewlineIndex := Pos(#10, FBuffer);
    if NewlineIndex > 0 then
    begin
      ALine := Copy(FBuffer, 1, NewlineIndex - 1);
      if (Length(ALine) > 0) and (ALine[Length(ALine)] = #13) then
        Delete(ALine, Length(ALine), 1);
      Delete(FBuffer, 1, NewlineIndex);
      Exit(True);
    end;

    fpFD_ZERO(ReadSet);
    fpFD_SET(FReadFd, ReadSet);
    TimeVal.tv_sec := ATimeoutMs div 1000;
    TimeVal.tv_usec := (ATimeoutMs mod 1000) * 1000;
    repeat
      Rc := fpSelect(FReadFd + 1, @ReadSet, nil, nil, @TimeVal);
    until (Rc >= 0) or (fpgeterrno <> ESysEINTR);
    if (Rc <= 0) or (fpFD_ISSET(FReadFd, ReadSet) <> 1) then
      Exit(False);

    repeat
      Got := fpRead(FReadFd, Buf, SizeOf(Buf));
    until (Got >= 0) or (fpgeterrno <> ESysEINTR);
    if Got <= 0 then
      Exit(False);
    SetString(ALine, PAnsiChar(@Buf[0]), Got);
    FBuffer := FBuffer + ALine;
  until False;
end;

function TConvexControlStream.WriteLine(const AText: string): Boolean;
var
  Payload: AnsiString;
  Sent, Total, Chunk: Integer;
  P: PAnsiChar;
begin
  Payload := AText + #10;
  Total := Length(Payload);
  Sent := 0;
  P := PAnsiChar(Payload);
  while Sent < Total do
  begin
    repeat
      Chunk := fpWrite(FWriteFd, P[Sent], Total - Sent);
    until (Chunk >= 0) or (fpgeterrno <> ESysEINTR);
    if Chunk <= 0 then
      Exit(False);
    Inc(Sent, Chunk);
  end;
  Result := True;
end;

end.
