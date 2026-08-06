param(
    [int] $Port = 43144,
    [string] $ReadyFile = '/tmp/powershell-http-fixture-ready',
    [string] $BindHost = '127.0.0.1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maximumBodyBytes = 8MB
$utf8 = [Text.UTF8Encoding]::new($false)
$listenAddress = if ($BindHost -in @('+', '*', '0.0.0.0')) {
    [Net.IPAddress]::Any
}
else {
    [Net.IPAddress]::Parse($BindHost)
}
$listener = [Net.Sockets.TcpListener]::new($listenAddress, $Port)

function Read-Request([Net.Sockets.NetworkStream] $Stream) {
    $headerBytes = [Collections.Generic.List[byte]]::new()
    while ($headerBytes.Count -lt 64KB) {
        $next = $Stream.ReadByte()
        if ($next -lt 0) { throw 'HTTP fixture reached EOF in request headers' }
        $headerBytes.Add([byte]$next)
        $count = $headerBytes.Count
        if (
            $count -ge 4 -and
            $headerBytes[$count - 4] -eq 13 -and
            $headerBytes[$count - 3] -eq 10 -and
            $headerBytes[$count - 2] -eq 13 -and
            $headerBytes[$count - 1] -eq 10
        ) {
            break
        }
    }
    if ($headerBytes.Count -ge 64KB) { throw 'HTTP fixture request headers were too large' }
    $headers = $utf8.GetString($headerBytes.ToArray())
    $contentLengthMatch = [regex]::Match($headers, '(?im)^Content-Length:\s*(\d+)\s*$')
    $contentLength = if ($contentLengthMatch.Success) { [int]$contentLengthMatch.Groups[1].Value } else { 0 }
    [byte[]]$body = [byte[]]::new($contentLength)
    $offset = 0
    while ($offset -lt $body.Length) {
        $read = $Stream.Read($body, $offset, $body.Length - $offset)
        if ($read -eq 0) { throw 'HTTP fixture reached EOF in request body' }
        $offset += $read
    }
    if ($body.Length -eq 0) { return @{} }
    $utf8.GetString($body) | ConvertFrom-Json -AsHashtable -Depth 64
}

function Write-Headers(
    [Net.Sockets.NetworkStream] $Stream,
    [int] $StatusCode,
    [string[]] $Headers
) {
    $reason = if ($StatusCode -eq 200) { 'OK' } elseif ($StatusCode -eq 400) { 'Bad Request' } else { 'Internal Server Error' }
    $lines = @("HTTP/1.1 $StatusCode $reason", 'Content-Type: application/json', 'Connection: close') + $Headers + @('', '')
    $bytes = $utf8.GetBytes(($lines -join "`r`n"))
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Write-FixedResponse(
    [Net.Sockets.NetworkStream] $Stream,
    [string] $Body,
    [int] $StatusCode = 200,
    [Nullable[long]] $DeclaredLength = $null
) {
    $bytes = $utf8.GetBytes($Body)
    $length = if ($null -ne $DeclaredLength) { [long]$DeclaredLength } else { [long]$bytes.Length }
    Write-Headers $Stream $StatusCode @("Content-Length: $length")
    if ($bytes.Length -gt 0) {
        $Stream.Write($bytes, 0, $bytes.Length)
        $Stream.Flush()
    }
}

function Write-Filler(
    [Net.Sockets.NetworkStream] $Stream,
    [long] $Length
) {
    [byte[]]$chunk = [byte[]]::new(16KB)
    [Array]::Fill[byte]($chunk, [byte][char]'x')
    $remaining = $Length
    while ($remaining -gt 0) {
        $count = [int][Math]::Min($remaining, $chunk.Length)
        $Stream.Write($chunk, 0, $count)
        $remaining -= $count
    }
}

function Write-SizedSuccessResponse(
    [Net.Sockets.NetworkStream] $Stream,
    [long] $BodyLength
) {
    $prefix = $utf8.GetBytes('{"status":"success","value":{"blob":"')
    $suffix = $utf8.GetBytes('"}}')
    $fillerLength = $BodyLength - $prefix.Length - $suffix.Length
    if ($fillerLength -lt 0) { throw 'HTTP fixture body length was too small' }
    Write-Headers $Stream 200 @("Content-Length: $BodyLength")
    $Stream.Write($prefix, 0, $prefix.Length)
    Write-Filler $Stream $fillerLength
    $Stream.Write($suffix, 0, $suffix.Length)
    $Stream.Flush()
}

function Write-FixedOverLimitResponse([Net.Sockets.NetworkStream] $Stream) {
    $bodyLength = [long]$maximumBodyBytes + 1
    Write-Headers $Stream 200 @("Content-Length: $bodyLength")
    Write-Filler $Stream $bodyLength
    $Stream.Flush()
}

function Write-Chunk(
    [Net.Sockets.NetworkStream] $Stream,
    [byte[]] $Bytes,
    [int] $Count = $Bytes.Length
) {
    $header = $utf8.GetBytes("$($Count.ToString('x'))`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($Bytes, 0, $Count)
    [byte[]]$ending = @(13, 10)
    $Stream.Write($ending, 0, $ending.Length)
    $Stream.Flush()
}

function Write-OverLimitChunkedResponse([Net.Sockets.NetworkStream] $Stream) {
    Write-Headers $Stream 200 @('Transfer-Encoding: chunked')
    [byte[]]$chunk = [byte[]]::new(16KB)
    [Array]::Fill[byte]($chunk, [byte][char]'x')
    $remaining = [long]$maximumBodyBytes + 1
    while ($remaining -gt 0) {
        $count = [int][Math]::Min($remaining, $chunk.Length)
        Write-Chunk $Stream $chunk $count
        $remaining -= $count
    }
    [byte[]]$empty = @()
    Write-Chunk $Stream $empty 0
}

function Write-OverLimitCloseDelimitedResponse([Net.Sockets.NetworkStream] $Stream) {
    Write-Headers $Stream 200 @()
    Write-Filler $Stream ([long]$maximumBodyBytes + 1)
    $Stream.Flush()
}

function Write-SlowResponse([Net.Sockets.NetworkStream] $Stream) {
    Write-Headers $Stream 200 @('Transfer-Encoding: chunked')
    $first = $utf8.GetBytes('{"status":')
    Write-Chunk $Stream $first
    Start-Sleep -Milliseconds 1000
    $last = $utf8.GetBytes('"success","value":true}')
    Write-Chunk $Stream $last
    [byte[]]$empty = @()
    Write-Chunk $Stream $empty 0
}

function Write-SlowOverLimitResponse([Net.Sockets.NetworkStream] $Stream) {
    Write-Headers $Stream 200 @('Transfer-Encoding: chunked')
    [byte[]]$chunk = [byte[]]::new(16KB)
    [Array]::Fill[byte]($chunk, [byte][char]'x')
    $remaining = [long]$maximumBodyBytes + 1
    while ($remaining -gt 0) {
        $count = [int][Math]::Min($remaining, $chunk.Length)
        Write-Chunk $Stream $chunk $count
        $remaining -= $count
        # Keep the peer deliberately slow without making the proof depend on a
        # sleep racing the client deadline. The client must stop on byte 8 MiB+1.
        Start-Sleep -Milliseconds 2
    }
    [byte[]]$empty = @()
    Write-Chunk $Stream $empty 0
}

$listener.Start()
[IO.File]::WriteAllText($ReadyFile, 'ready', $utf8)
$stop = $false
try {
    while (-not $stop) {
        $tcp = $listener.AcceptTcpClient()
        try {
            $tcp.NoDelay = $true
            $stream = $tcp.GetStream()
            $request = Read-Request $stream
            $path = if ($request -is [hashtable] -and $request.ContainsKey('path')) { [string]$request['path'] } else { '' }
            try {
                switch ($path) {
                    'fixture:http4xxSuccess' { Write-FixedResponse $stream '{"status":"success","value":true}' 400 }
                    'fixture:http5xxSuccess' { Write-FixedResponse $stream '{"status":"success","value":true}' 500 }
                    'fixture:httpScalar' { Write-FixedResponse $stream '42' }
                    'fixture:httpArray' { Write-FixedResponse $stream '[]' }
                    'fixture:httpNull' { Write-FixedResponse $stream 'null' }
                    'fixture:httpMalformed' { Write-FixedResponse $stream '{"status":' }
                    'fixture:httpMissingStatus' { Write-FixedResponse $stream '{"value":true}' }
                    'fixture:httpStatusType' { Write-FixedResponse $stream '{"status":1,"value":true}' }
                    'fixture:httpUnknownStatus' { Write-FixedResponse $stream '{"status":"maybe","value":true}' }
                    'fixture:httpMissingValue' { Write-FixedResponse $stream '{"status":"success"}' }
                    'fixture:httpMissingErrorMessage' { Write-FixedResponse $stream '{"status":"error"}' }
                    'fixture:httpErrorMessageType' { Write-FixedResponse $stream '{"status":"error","errorMessage":12}' }
                    'fixture:httpLogLinesType' { Write-FixedResponse $stream '{"status":"success","value":true,"logLines":"bad"}' }
                    'fixture:httpLogLineType' { Write-FixedResponse $stream '{"status":"success","value":true,"logLines":[1]}' }
                    'fixture:httpFunctionError' { Write-FixedResponse $stream '{"status":"error","errorMessage":"expected raw failure","errorData":{"code":"RAW"},"logLines":["raw log"]}' }
                    'fixture:httpExactBoundary' { Write-SizedSuccessResponse $stream $maximumBodyBytes }
                    'fixture:httpFixedOverLimit' { Write-FixedOverLimitResponse $stream }
                    'fixture:httpDishonestLength' { Write-FixedResponse $stream '{}' 200 1GB }
                    'fixture:httpChunkedOverLimit' { Write-OverLimitChunkedResponse $stream }
                    'fixture:httpNoLengthOverLimit' { Write-OverLimitCloseDelimitedResponse $stream }
                    'fixture:httpSlow' { Write-SlowResponse $stream }
                    'fixture:httpSlowOverLimit' { Write-SlowOverLimitResponse $stream }
                    'fixture:httpShutdown' {
                        Write-FixedResponse $stream '{"status":"success","value":true}'
                        $stop = $true
                    }
                    default { Write-FixedResponse $stream '{"status":"success","value":{"recovered":true}}' }
                }
            }
            catch [IO.IOException] {
                # Oversize and cancelled clients deliberately abandon the stream.
            }
            catch [Net.Sockets.SocketException] {
                # The next accepted connection proves the fixture remains usable.
            }
        }
        finally {
            $tcp.Dispose()
        }
    }
}
finally {
    $listener.Stop()
}
