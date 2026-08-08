{ A minimal RFC 6455 WebSocket client used only to carry the pinned
  `convex-rs' sync profile's JSON messages (see docs/protocol-profiles.md
  in the repository root). It implements exactly what that profile needs:
  the HTTP Upgrade handshake, masked text frames outbound, fragmented-
  message reassembly and control frames (ping/pong/close) inbound, and a
  bounded read so a stalled or hostile peer cannot block the adapter's
  single I/O owner. It is not a general-purpose WebSocket library: binary
  frames and extensions are out of scope.

  Frames are parsed atomically: a frame's header and payload are only
  ever removed from the read buffer together, once the whole frame is
  confirmed present. A version that consumed the header first and the
  payload in a second, separate step could leave the buffer holding a
  header with no matching payload if the payload arrived in a later TCP
  segment, corrupting every later parse; that failure mode only shows up
  over real network latency; it never reproduces on a local loopback
  connection where a whole frame typically lands in one read. }
unit ConvexWebSocket;

{$mode delphi}

interface

uses
  SysUtils, ConvexSocket;

type
  TConvexWebSocket = class
  private
    FSocket: TConvexSocket;
    FIsOpen: Boolean;
    FLastError: string;
    FLastCloseReason: string;
    FBuffer: AnsiString;
    FLastFrameFin: Boolean;
    FLastFrameOpcode: Integer;
    FLastPayload: AnsiString;

    function ReadLine(ATimeoutMs: Integer; out ALine: string): Boolean;
    procedure DrainHandshakeHeaders;
    function FillBuffer(AMinBytes, ATimeoutMs: Integer): Boolean;
    function TryParseFrame(ATimeoutMs: Integer): Boolean;
    function EncodeFrame(AOpcode: Integer; const APayload: AnsiString): AnsiString;
    function ClosePayload(const AReason: string): AnsiString;
    function CloseReasonFromPayload(const APayload: AnsiString): string;
    procedure SendCloseAck;
    function Base64Encode(const ABytes: AnsiString): string;
  public
    // Open a TCP (or TLS) connection to AHost:APort and complete the
    // WebSocket handshake against APath. Check IsOpen and LastError
    // afterwards.
    constructor Create(const AHost: string; APort: Word; const APath: string; AUseTls: Boolean);
    destructor Destroy; override;

    property IsOpen: Boolean read FIsOpen;
    property LastError: string read FLastError;
    // The most recently observed reason a connection ended: a peer
    // close frame's reason text, "timeout", "transport error", or
    // "InitialConnect" before any connection has ended yet.
    property LastCloseReason: string read FLastCloseReason;
    // The raw file descriptor, exposed so the adapter can select() on it
    // alongside its control stream.
    function Descriptor: THandle;
    // Does the transport already hold decoded bytes (or does the read
    // buffer already hold a complete frame) that a select loop must
    // drain before waiting on the descriptor again?
    function HasPendingBytes: Boolean;

    // Send AText as one unfragmented, masked WebSocket text frame.
    // Returns False (with LastError set) on failure.
    function SendText(const AText: string): Boolean;

    // Wait up to ATimeoutMs for one complete text message, reassembling
    // fragments and transparently answering pings and the peer's close
    // handshake. Returns False on timeout, close, or error (see IsOpen
    // and LastError to distinguish those); AMessage is only meaningful
    // when this returns True.
    function TryReceiveMessage(ATimeoutMs: Integer; out AMessage: string): Boolean;

    // Send a close frame carrying AReason and shut the connection down.
    // Idempotent; safe to call after the peer has already closed.
    procedure Close(const AReason: string);
  end;

implementation

const
  OpcodeText = 1;
  OpcodeClose = 8;
  OpcodePing = 9;
  OpcodePong = 10;
  HandshakeTimeoutMs = 10000;

constructor TConvexWebSocket.Create(const AHost: string; APort: Word; const APath: string; AUseTls: Boolean);
var
  Key, Request, StatusLine: string;
begin
  inherited Create;
  FBuffer := '';
  FLastPayload := '';
  FLastCloseReason := 'InitialConnect';
  FSocket := TConvexSocket.Create(AHost, APort, AUseTls);
  if not FSocket.IsOpen then
  begin
    FLastError := FSocket.LastError;
    Exit;
  end;

  // RFC 6455 does not require cryptographic randomness in the
  // handshake key: the server only hashes it to prove it understood the
  // request, and this client never reuses a connection across origins,
  // so there is nothing to defend by varying the key between handshakes.
  Key := Base64Encode('ConvexPascalWS16');
  Request := 'GET ' + APath + ' HTTP/1.1'#13#10
    + 'Host: ' + AHost + #13#10
    + 'Upgrade: websocket'#13#10
    + 'Connection: Upgrade'#13#10
    + 'Sec-WebSocket-Key: ' + Key + #13#10
    + 'Sec-WebSocket-Version: 13'#13#10#13#10;
  if not FSocket.WriteAll(Request) then
  begin
    FLastError := 'handshake request failed: ' + FSocket.LastError;
    FSocket.Close;
    Exit;
  end;

  if not ReadLine(HandshakeTimeoutMs, StatusLine) then
  begin
    FLastError := 'no handshake response';
    FSocket.Close;
    Exit;
  end;
  if Pos('101', StatusLine) = 0 then
  begin
    FLastError := 'unexpected handshake status: ' + StatusLine;
    FSocket.Close;
    Exit;
  end;

  DrainHandshakeHeaders;
  FIsOpen := True;
end;

destructor TConvexWebSocket.Destroy;
begin
  FSocket.Free;
  inherited Destroy;
end;

function TConvexWebSocket.Descriptor: THandle;
begin
  Result := FSocket.Handle;
end;

function TConvexWebSocket.HasPendingBytes: Boolean;
begin
  Result := FSocket.PendingBytes or (Length(FBuffer) > 0);
end;

function TConvexWebSocket.ReadLine(ATimeoutMs: Integer; out ALine: string): Boolean;
var
  NewlineIndex: Integer;
  Chunk: string;
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
      Result := True;
      Exit;
    end
    else if FSocket.ReadSome(4096, ATimeoutMs, Chunk) then
      FBuffer := FBuffer + Chunk
    else
      Exit(False);
  until False;
end;

procedure TConvexWebSocket.DrainHandshakeHeaders;
var
  Line: string;
begin
  while ReadLine(HandshakeTimeoutMs, Line) do
    if Line = '' then
      Exit;
end;

function TConvexWebSocket.FillBuffer(AMinBytes, ATimeoutMs: Integer): Boolean;
  // Ensure FBuffer holds at least AMinBytes, reading more from the
  // socket as needed, one read per still-missing fragment. False on
  // timeout or transport error. A read that returns False always ends
  // this call rather than retrying with a fresh deadline: a message
  // fragmented across several TCP segments (routine over a real
  // network, rare on localhost) previously risked spinning across
  // many short reads until every fragment had arrived, which made a
  // rare interrupted syscall from the runtime's own signals far more
  // likely to land badly than the single bounded wait here does.
var
  Chunk: string;
begin
  while (Length(FBuffer) < AMinBytes) and FIsOpen do
  begin
    if FSocket.ReadSome(4096, ATimeoutMs, Chunk) then
      FBuffer := FBuffer + Chunk
    else
    begin
      if FSocket.IsOpen then
        FLastError := 'read timed out'
      else
      begin
        FLastError := FSocket.LastError;
        FIsOpen := False;
      end;
      Break;
    end;
  end;
  Result := Length(FBuffer) >= AMinBytes;
end;

function TConvexWebSocket.TryParseFrame(ATimeoutMs: Integer): Boolean;
  // Parse one complete frame (header and payload together) from
  // FBuffer, reading more data as needed. Bytes are only ever removed
  // from FBuffer once an entire frame is confirmed present, so a call
  // that cannot complete within ATimeoutMs leaves FBuffer exactly as it
  // found it: a later call safely resumes from those same bytes plus
  // whatever has since arrived, rather than mistaking an
  // already-consumed frame's leftover payload bytes for the start of a
  // new header.
var
  Byte0, Byte1, BaseLength, HeaderSize, PayloadLength, ExtStart, TotalSize: Integer;
begin
  Result := False;
  if not FillBuffer(2, ATimeoutMs) then
    Exit;
  Byte0 := Ord(FBuffer[1]);
  Byte1 := Ord(FBuffer[2]);
  BaseLength := Byte1 and $7F;
  // Servers never mask frames sent to the client (RFC 6455 5.1).
  if BaseLength = 126 then
    HeaderSize := 4
  else if BaseLength = 127 then
    HeaderSize := 10
  else
    HeaderSize := 2;
  if not FillBuffer(HeaderSize, ATimeoutMs) then
    Exit;
  if BaseLength = 126 then
    PayloadLength := Ord(FBuffer[3]) * 256 + Ord(FBuffer[4])
  else if BaseLength = 127 then
  begin
    // This client's frames never approach 2^31 bytes; treat the
    // length as the low-order bytes only.
    PayloadLength := 0;
    for ExtStart := 7 to 10 do
      PayloadLength := PayloadLength * 256 + Ord(FBuffer[ExtStart]);
  end
  else
    PayloadLength := BaseLength;
  TotalSize := HeaderSize + PayloadLength;
  if not FillBuffer(TotalSize, ATimeoutMs) then
    Exit;
  FLastFrameFin := (Byte0 and $80) <> 0;
  FLastFrameOpcode := Byte0 and $0F;
  FLastPayload := Copy(FBuffer, HeaderSize + 1, PayloadLength);
  Delete(FBuffer, 1, TotalSize);
  Result := True;
end;

function TConvexWebSocket.EncodeFrame(AOpcode: Integer; const APayload: AnsiString): AnsiString;
  // Build one final, masked frame carrying APayload. Every
  // client-to-server frame must be masked (RFC 6455 5.1); the mask key
  // does not need to be unpredictable, only present.
const
  Mask: array[0..3] of Byte = (37, 111, 199, 251);
var
  PayloadLen, I: Integer;
  Frame: AnsiString;
begin
  PayloadLen := Length(APayload);
  Frame := '';
  Frame := Frame + AnsiChar(Chr($80 + AOpcode));
  if PayloadLen <= 125 then
    Frame := Frame + AnsiChar(Chr($80 + PayloadLen))
  else if PayloadLen <= 65535 then
  begin
    Frame := Frame + AnsiChar(Chr($80 + 126));
    Frame := Frame + AnsiChar(Chr((PayloadLen shr 8) and $FF));
    Frame := Frame + AnsiChar(Chr(PayloadLen and $FF));
  end
  else
  begin
    Frame := Frame + AnsiChar(Chr($80 + 127));
    for I := 1 to 4 do
      Frame := Frame + AnsiChar(Chr(0));
    Frame := Frame + AnsiChar(Chr((PayloadLen shr 24) and $FF));
    Frame := Frame + AnsiChar(Chr((PayloadLen shr 16) and $FF));
    Frame := Frame + AnsiChar(Chr((PayloadLen shr 8) and $FF));
    Frame := Frame + AnsiChar(Chr(PayloadLen and $FF));
  end;
  for I := 0 to 3 do
    Frame := Frame + AnsiChar(Chr(Mask[I]));
  for I := 1 to PayloadLen do
    Frame := Frame + AnsiChar(Chr(Ord(APayload[I]) xor Mask[(I - 1) mod 4]));
  Result := Frame;
end;

function TConvexWebSocket.ClosePayload(const AReason: string): AnsiString;
  // A close-frame payload carrying status code 1000 (normal closure)
  // and AReason as UTF-8 text.
const
  StatusCode = 1000;
begin
  Result := AnsiChar(Chr((StatusCode shr 8) and $FF)) + AnsiChar(Chr(StatusCode and $FF)) + AReason;
end;

function TConvexWebSocket.CloseReasonFromPayload(const APayload: AnsiString): string;
begin
  if Length(APayload) > 2 then
    Result := Copy(APayload, 3, Length(APayload) - 2)
  else
    Result := 'closed by peer';
end;

procedure TConvexWebSocket.SendCloseAck;
begin
  if FSocket.IsOpen then
    FSocket.WriteAll(EncodeFrame(OpcodeClose, ClosePayload('ack')));
end;

function TConvexWebSocket.SendText(const AText: string): Boolean;
begin
  Result := FSocket.WriteAll(EncodeFrame(OpcodeText, AText));
  if not Result then
  begin
    FLastError := FSocket.LastError;
    FIsOpen := False;
  end;
end;

function TConvexWebSocket.TryReceiveMessage(ATimeoutMs: Integer; out AMessage: string): Boolean;
var
  Message: AnsiString;
  FirstOpcode: Integer;
  Done: Boolean;
  DeadlineMs: Integer;
begin
  Result := False;
  Message := '';
  FirstOpcode := -1;
  DeadlineMs := ATimeoutMs;
  Done := False;
  while not Done do
  begin
    if not TryParseFrame(DeadlineMs) then
      Done := True
    else
      case FLastFrameOpcode of
        OpcodePing:
          if not FSocket.WriteAll(EncodeFrame(OpcodePong, FLastPayload)) then
          begin
            FLastError := FSocket.LastError;
            FIsOpen := False;
            Done := True;
          end;
        OpcodePong:
          ; // Nothing to do; a pong on its own is not a message.
        OpcodeClose:
          begin
            FLastCloseReason := CloseReasonFromPayload(FLastPayload);
            SendCloseAck;
            FIsOpen := False;
            FSocket.Close;
            Done := True;
          end;
      else
        begin
          if FirstOpcode = -1 then
            FirstOpcode := FLastFrameOpcode;
          Message := Message + FLastPayload;
          if FLastFrameFin then
          begin
            Done := True;
            if FirstOpcode = OpcodeText then
            begin
              AMessage := Message;
              Result := True;
            end;
          end;
        end;
      end;
  end;
end;

procedure TConvexWebSocket.Close(const AReason: string);
begin
  if FIsOpen then
  begin
    FSocket.WriteAll(EncodeFrame(OpcodeClose, ClosePayload(AReason)));
    FIsOpen := False;
  end;
  FSocket.Close;
end;

function TConvexWebSocket.Base64Encode(const ABytes: AnsiString): string;
const
  Alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  I, B0, B1, B2, Triple: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(ABytes) do
  begin
    B0 := Ord(ABytes[I]);
    if I + 1 <= Length(ABytes) then
      B1 := Ord(ABytes[I + 1])
    else
      B1 := 0;
    if I + 2 <= Length(ABytes) then
      B2 := Ord(ABytes[I + 2])
    else
      B2 := 0;
    Triple := B0 * 65536 + B1 * 256 + B2;
    Result := Result + Alphabet[((Triple shr 18) and $3F) + 1];
    Result := Result + Alphabet[((Triple shr 12) and $3F) + 1];
    if I + 1 <= Length(ABytes) then
      Result := Result + Alphabet[((Triple shr 6) and $3F) + 1]
    else
      Result := Result + '=';
    if I + 2 <= Length(ABytes) then
      Result := Result + Alphabet[(Triple and $3F) + 1]
    else
      Result := Result + '=';
    Inc(I, 3);
  end;
end;

end.
