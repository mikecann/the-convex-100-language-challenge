{ A minimal TCP socket, optionally wrapped in TLS, used by CONVEX_WEBSOCKET
  for the Live connection (query/mutation/action go through
  TConvexHttpClient/TFPHTTPClient directly instead). Built on Free
  Pascal's bundled ssockets/opensslsockets units rather than hand-rolled
  OpenSSL calls: TInetSocket already gives a blocking byte stream over
  either a plain or (through TSSLSocketHandler) TLS-wrapped connection,
  with certificate and hostname verification through ordinary published
  properties, which is the same "normal HTTP, TLS" library allowance
  every native client in this project relies on.

  Every read carries an explicit millisecond deadline, checked with a
  real select(2) call before ever touching the stream, so a stalled or
  malicious peer cannot block the adapter's single I/O owner forever. }
unit ConvexSocket;

{$mode delphi}

interface

uses
  Classes, SysUtils, ssockets, sslsockets, sslbase, sockets, opensslsockets, BaseUnix, Unix;

type
  TConvexSocket = class
  private
    FStream: TInetSocket;
    FHandler: TSocketHandler;
    FIsOpen: Boolean;
    FLastError: string;
    function GetHandleValue: THandle;
  public
    // Open a TCP connection to AHost:APort, completing a TLS handshake
    // (with SNI and certificate/hostname verification) when AUseTls.
    // Check IsOpen and LastError afterwards.
    constructor Create(const AHost: string; APort: Word; AUseTls: Boolean);
    destructor Destroy; override;

    // Write every byte of AData, blocking as needed. Returns False (with
    // LastError set) on any failure.
    function WriteAll(const AData: string): Boolean;

    // Wait up to ATimeoutMs for the connection to have a byte ready,
    // either already buffered inside the TLS layer or newly arrived on
    // the wire.
    function WaitReadable(ATimeoutMs: Integer): Boolean;

    // Read between 1 and AMaxBytes bytes into AData, waiting up to
    // ATimeoutMs for the first byte. Returns False (AData undefined) on
    // timeout or error; see IsOpen/LastError to distinguish those.
    function ReadSome(AMaxBytes, ATimeoutMs: Integer; out AData: string): Boolean;

    procedure Close;

    // Does the TLS layer already hold decrypted application bytes from
    // a previous read of the raw socket? A plain select(2) on Handle
    // only reports newly arrived bytes on the wire; once OpenSSL has
    // pulled a whole TLS record off the wire and decrypted it, further
    // buffered plaintext can sit inside the library with nothing left
    // to select() on, so a caller multiplexing this socket alongside
    // other descriptors must check this first or it can stall waiting
    // on a socket that already has data ready.
    function PendingBytes: Boolean;

    property IsOpen: Boolean read FIsOpen;
    property LastError: string read FLastError;
    property Handle: THandle read GetHandleValue;
  end;

implementation

// fpc's TOpenSSLSocketHandler never calls the OpenSSL library's own
// "use the system default trust store" setup (SSL_CTX_set_default_verify_paths
// is not bound anywhere in packages/openssl/src/openssl.pas); it only loads
// a CA bundle when CertificateData.CertCA.FileName is set explicitly. With
// VerifyPeerCert on and no bundle configured, SSL_CTX_set_verify still runs
// in SSL_VERIFY_PEER mode with nothing to verify against, so every single
// handshake fails with "certificate verify failed" -- even against a
// perfectly valid public certificate. This locates the distro CA bundle so
// verification has something real to check against; the runtime image is
// Debian-based (see Dockerfile) and always installs ca-certificates, so the
// first candidate is expected to be the one that actually gets used.
function DefaultCaBundlePath: string;
const
  Candidates: array[0..3] of string = (
    '/etc/ssl/certs/ca-certificates.crt',
    '/etc/pki/tls/certs/ca-bundle.crt',
    '/etc/ssl/cert.pem',
    '/usr/local/etc/openssl/cert.pem'
  );
var
  I: Integer;
begin
  Result := '';
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then
      Exit(Candidates[I]);
end;

constructor TConvexSocket.Create(const AHost: string; APort: Word; AUseTls: Boolean);
var
  SslHandler: TOpenSSLSocketHandler;
begin
  inherited Create;
  FHandler := nil;
  FStream := nil;
  try
    if AUseTls then
    begin
      SslHandler := TOpenSSLSocketHandler.Create;
      SslHandler.SSLType := stTLSv1_2;
      SslHandler.SendHostAsSNI := True;
      SslHandler.VerifyPeerCert := True;
      SslHandler.CertificateData.CertCA.FileName := DefaultCaBundlePath;
      FHandler := SslHandler;
    end;
    FStream := TInetSocket.Create(AHost, APort, 10000, FHandler);
    // From this point, FStream owns FHandler and frees it in its own
    // destructor (TSocketStream.Destroy); this class must not also free
    // FHandler once FStream exists, or Destroy below double-frees it.
    // TInetSocket.Create only connects automatically when it is not given
    // a handler ("backwards compatible behaviour", its own comment); with
    // one supplied (always, here, so the TLS handshake happens through
    // it) the connect call is this class's own responsibility.
    if FHandler <> nil then
      FStream.Connect;
    FIsOpen := True;
  except
    on E: Exception do
    begin
      FLastError := 'connect failed: ' + E.Message;
      if AUseTls and (SslHandler <> nil) and (SslHandler.SSLLastErrorString <> '') then
        FLastError := FLastError + ' (' + SslHandler.SSLLastErrorString + ')';
      FIsOpen := False;
      if FStream <> nil then
      begin
        FStream.Free;
        FStream := nil;
      end
      else
        FHandler.Free;
      FHandler := nil;
    end;
  end;
end;

destructor TConvexSocket.Destroy;
begin
  Close;
  FStream.Free;
  // TInetSocket takes ownership of the handler it is given and frees it
  // itself; do not free FHandler again here.
  inherited Destroy;
end;

function TConvexSocket.GetHandleValue: THandle;
begin
  Result := FStream.Handle;
end;

function TConvexSocket.WriteAll(const AData: string): Boolean;
var
  Sent, Total, Chunk: Integer;
  P: PAnsiChar;
begin
  Result := True;
  Total := Length(AData);
  Sent := 0;
  P := PAnsiChar(AData);
  while Sent < Total do
  begin
    try
      Chunk := FStream.Write(P[Sent], Total - Sent);
    except
      on E: Exception do
      begin
        FLastError := 'write failed: ' + E.Message;
        FIsOpen := False;
        Exit(False);
      end;
    end;
    if Chunk <= 0 then
    begin
      FLastError := 'write failed';
      FIsOpen := False;
      Exit(False);
    end;
    Inc(Sent, Chunk);
  end;
end;

function TConvexSocket.WaitReadable(ATimeoutMs: Integer): Boolean;
var
  ReadSet: TFDSet;
  TimeVal: TTimeVal;
  Rc: Longint;
  Fd: Longint;
begin
  if (FHandler <> nil) and (FHandler.BytesAvailable > 0) then
    Exit(True);
  Fd := FStream.Handle;
  fpFD_ZERO(ReadSet);
  fpFD_SET(Fd, ReadSet);
  TimeVal.tv_sec := ATimeoutMs div 1000;
  TimeVal.tv_usec := (ATimeoutMs mod 1000) * 1000;
  repeat
    Rc := fpSelect(Fd + 1, @ReadSet, nil, nil, @TimeVal);
  until (Rc >= 0) or (fpGetErrno <> ESysEINTR);
  Result := (Rc > 0) and (fpFD_ISSET(Fd, ReadSet) = 1);
end;

function TConvexSocket.ReadSome(AMaxBytes, ATimeoutMs: Integer; out AData: string): Boolean;
var
  Buffer: array of Byte;
  Got: Integer;
begin
  AData := '';
  if not WaitReadable(ATimeoutMs) then
    Exit(False);
  SetLength(Buffer, AMaxBytes);
  try
    Got := FStream.Read(Buffer[0], AMaxBytes);
  except
    on E: Exception do
    begin
      FLastError := 'read failed: ' + E.Message;
      FIsOpen := False;
      Exit(False);
    end;
  end;
  if Got > 0 then
  begin
    SetString(AData, PAnsiChar(@Buffer[0]), Got);
    Result := True;
  end
  else if Got = 0 then
  begin
    FLastError := 'connection closed by peer';
    FIsOpen := False;
    Result := False;
  end
  else
  begin
    FLastError := 'read failed';
    FIsOpen := False;
    Result := False;
  end;
end;

procedure TConvexSocket.Close;
begin
  FIsOpen := False;
end;

function TConvexSocket.PendingBytes: Boolean;
begin
  Result := (FHandler <> nil) and (FHandler.BytesAvailable > 0);
end;

end.
