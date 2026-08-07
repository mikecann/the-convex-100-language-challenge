SuperStrict

' Byte-level transport for the BlitzMax Convex client.
'
' Everything Convex-specific lives above this file. This layer owns only four
' concerns: an absolute monotonic deadline, a growable byte buffer, UTF-8
' validation, and one TCP-or-TLS connection built from BlitzMax NG's stock
' mbed TLS module.

Import Net.mbedtls

' A tiny C shim, not the Convex protocol itself. clock_gettime and
' mbedtls_ctr_drbg_random are both already declared elsewhere with types
' BlitzMax cannot spell exactly (a real struct timespec*, and the Object-typed
' callback binding Net.mbedtls exposes for its own internal use). Binding a
' second BlitzMax extern straight onto either C symbol name would give that
' symbol two conflicting prototypes in the same translation unit, which is a
' hard compile error rather than a warning. The shim file forwards to both
' functions under names of its own, so the bindings below only ever have to
' describe the shim, never the library symbol underneath it.
Import "convex_glue.c"

' BlitzMax NG has no monotonic clock, no readiness check for a plain file
' descriptor, and no environment accessor outside a module's private glue, so
' those come straight from libc. They are pure POSIX; nothing Convex-specific
' crosses this boundary.
Extern
	Function convex_poll:Int(fds:Int Ptr, nfds:Size_T, timeoutMs:Int) = "poll"
	Function convex_read:Long(fd:Int, buf:Byte Ptr, count:Size_T) = "read"
	Function convex_write:Long(fd:Int, buf:Byte Ptr, count:Size_T) = "write"
	Function convex_clock_gettime:Int(clockId:Int, spec:Long Ptr) = "convex_glue_clock_gettime"
	Function convex_getenv:Byte Ptr(name:Byte Ptr) = "getenv"
	Function convex_strlen:Size_T(text:Byte Ptr) = "strlen"
	' mbed TLS is linked by Net.mbedtls but its BlitzMax wrapper exposes neither
	' the seeded generator nor SNI as a plain-pointer call. Both are public
	' mbed TLS entry points and both take the same raw handles the wrapper
	' already hands out; see convex_glue.c for why they go through a shim.
	Function convex_ctr_drbg_random:Int(context:Byte Ptr, output:Byte Ptr, length:Size_T) = "convex_glue_ctr_drbg_random"
	Function convex_ssl_set_hostname:Int(ssl:Byte Ptr, hostname:Byte Ptr) = "convex_glue_ssl_set_hostname"
End Extern

Const CONVEX_CLOCK_MONOTONIC:Int = 1
Const CONVEX_POLLIN:Int = 1
Const CONVEX_POLLOUT:Int = 4

' Everything the client reads or writes is bounded by these numbers.
Const CONVEX_MAX_HTTP_BODY_BYTES:Int = 2 * 1024 * 1024
Const CONVEX_MAX_FRAME_BYTES:Int = 2 * 1024 * 1024
Const CONVEX_IO_CHUNK_BYTES:Int = 8192

Rem
bbdoc: Cooperative work to run while the client is waiting on a socket.
about: Production leaves this unset. The language-local hostile-peer tests set
it so one thread can act as both the client and the misbehaving server, which
keeps those tests deterministic instead of racing two schedulers.
End Rem
Global ConvexIdleHook:Int()

Function ConvexIdle()
	If ConvexIdleHook Then
		ConvexIdleHook()
	End If
End Function

Rem
bbdoc: Structured client failure.
about: The kinds map onto the adapter's error names, so a failure never loses
the distinction between "the function said no", "the peer spoke nonsense", and
"the connection broke".
End Rem
Type TConvexError

	Const KIND_TRANSPORT:Int = 1
	Const KIND_PROTOCOL:Int = 2
	Const KIND_FUNCTION:Int = 3
	Const KIND_CLOSED:Int = 4

	Field kind:Int
	Field message:String

	Function Create:TConvexError(kind:Int, message:String)
		Local this:TConvexError = New TConvexError
		this.kind = kind
		this.message = message
		Return this
	End Function

	Function Transport:TConvexError(message:String)
		Return Create(KIND_TRANSPORT, message)
	End Function

	Function Protocol:TConvexError(message:String)
		Return Create(KIND_PROTOCOL, message)
	End Function

	Function Shut:TConvexError(message:String)
		Return Create(KIND_CLOSED, message)
	End Function

	Rem
	bbdoc: The adapter error name for this failure.
	End Rem
	Method Name:String()
		If kind = KIND_PROTOCOL Then
			Return "ProtocolError"
		End If
		If kind = KIND_FUNCTION Then
			Return "FunctionError"
		End If
		Return "TransportError"
	End Method

	Method ToString:String() Override
		Return Name() + ": " + message
	End Method

End Type

Rem
bbdoc: Reads an environment variable, returning an empty string when unset.
End Rem
Function ConvexEnv:String(name:String)
	Local encoded:Byte Ptr = name.ToUTF8String()
	Local value:Byte Ptr = convex_getenv(encoded)
	MemFree(encoded)
	If Not value Then
		Return ""
	End If
	Return String.FromUTF8String(value)
End Function

Rem
bbdoc: Milliseconds from an arbitrary fixed point on the monotonic clock.
about: Wall-clock time can jump backwards. Every deadline in this client is
computed from this instead, so a clock adjustment cannot extend an operation.
End Rem
Function ConvexNowMs:Long()
	' struct timespec is two native words: seconds then nanoseconds.
	Local spec:Long[2]
	If convex_clock_gettime(CONVEX_CLOCK_MONOTONIC, Varptr spec[0]) <> 0 Then
		Return 0
	End If
	Return spec[0] * 1000 + spec[1] / 1000000
End Function

Rem
bbdoc: One absolute deadline for a whole operation.
about: An inactivity timeout is not a deadline: a peer that sends one byte
every half second holds an inactivity-based reader open forever. Each operation
creates one of these once, and every wait inside it shrinks against the same
expiry.
End Rem
Type TConvexDeadline

	Field expiry:Long

	Function Create:TConvexDeadline(budgetMs:Int)
		Local this:TConvexDeadline = New TConvexDeadline
		this.expiry = ConvexNowMs() + budgetMs
		Return this
	End Function

	Method Expired:Int()
		Return ConvexNowMs() >= expiry
	End Method

	Rem
	bbdoc: Milliseconds left, clamped so it is always a usable poll timeout.
	End Rem
	Method RemainingMs:Int()
		Local left:Long = expiry - ConvexNowMs()
		If left <= 0 Then
			Return 0
		End If
		If left > 60000 Then
			Return 60000
		End If
		Return Int(left)
	End Method

End Type

Rem
bbdoc: Waits for a plain file descriptor to become ready.
returns: 1 when ready, 0 on timeout, -1 on error.
End Rem
Function ConvexPollFd:Int(fd:Int, events:Int, timeoutMs:Int)
	' struct pollfd on linux/amd64 is { int fd; short events; short revents; },
	' so two Ints cover it exactly and the revents halfword lands in the high
	' bits of the second Int on this little-endian target.
	Local descriptor:Int[2]
	descriptor[0] = fd
	descriptor[1] = events & $FFFF
	Local ready:Int = convex_poll(Varptr descriptor[0], Size_T(1), timeoutMs)
	If ready <= 0 Then
		Return ready
	End If
	If ((descriptor[1] Shr 16) & $FFFF) = 0 Then
		Return 0
	End If
	Return 1
End Function

Rem
bbdoc: A growable byte buffer with an explicit length.
about: Network code appends fragments and consumes completed prefixes without
paying quadratic string concatenation, and every memory bound in this client is
stated in bytes, so buffers are bytes rather than BlitzMax strings.
End Rem
Type TConvexBuffer

	Field data:Byte[]
	Field length:Int

	Function Create:TConvexBuffer(capacity:Int = 256)
		Local this:TConvexBuffer = New TConvexBuffer
		If capacity < 32 Then
			capacity = 32
		End If
		this.data = New Byte[capacity]
		this.length = 0
		Return this
	End Function

	Method Reset()
		length = 0
	End Method

	Method Reserve(extra:Int)
		If length + extra <= data.length Then
			Return
		End If
		Local grown:Int = data.length
		While grown < length + extra
			grown = grown * 2
		Wend
		data = data[..grown]
	End Method

	Method AppendByte(value:Int)
		Reserve(1)
		data[length] = Byte(value & $FF)
		length :+ 1
	End Method

	Method AppendBytes(source:Byte Ptr, count:Int)
		If count <= 0 Then
			Return
		End If
		Reserve(count)
		MemCopy(Varptr data[length], source, Size_T(count))
		length :+ count
	End Method

	Rem
	bbdoc: Appends the UTF-8 encoding of @text.
	about: Callers only ever append JSON, whose control characters are escaped,
	so an interior NUL cannot silently truncate the appended run.
	End Rem
	Method AppendString(text:String)
		If text.length = 0 Then
			Return
		End If
		Local encoded:Byte Ptr = text.ToUTF8String()
		AppendBytes(encoded, Int(convex_strlen(encoded)))
		MemFree(encoded)
	End Method

	Rem
	bbdoc: Drops the first @count bytes and keeps the remainder at the front.
	End Rem
	Method Consume(count:Int)
		If count <= 0 Then
			Return
		End If
		If count >= length Then
			length = 0
			Return
		End If
		MemMove(Varptr data[0], Varptr data[count], Size_T(length - count))
		length :- count
	End Method

	Rem
	bbdoc: Decodes the first @count bytes as UTF-8 text.
	End Rem
	Method TextPrefix:String(count:Int)
		If count <= 0 Then
			Return ""
		End If
		Return String.FromUTF8Bytes(data, count)
	End Method

	Method ToText:String()
		Return TextPrefix(length)
	End Method

	Rem
	bbdoc: True when any of the first @count bytes is NUL.
	about: A NUL cannot appear in valid JSON text, and letting one through would
	silently truncate the decoded string rather than fail.
	End Rem
	Method HasInteriorNul:Int(count:Int)
		For Local index:Int = 0 Until count
			If data[index] = 0 Then
				Return True
			End If
		Next
		Return False
	End Method

End Type

Rem
bbdoc: Encodes @text as one LF-terminated line, never BlitzMax's platform CRLF.
about: BRL.Stream's WriteLine always appends the two bytes 13 and 10, even on
Linux targets, because the terminator is hard-coded rather than chosen per
platform. Anything that must produce an exact, portable line ending — this
client's canonical example transcript, for instance, which the harness
compares byte-for-byte against a checked-in LF-only transcript — builds its
line with this instead of going through Print or WriteLine.
End Rem
Function ConvexEncodeLine:TConvexBuffer(text:String)
	Local line:TConvexBuffer = TConvexBuffer.Create(text.length + 2)
	line.AppendString(text)
	line.AppendByte(10)
	Return line
End Function

Rem
bbdoc: Validates that the first @count bytes of @data are well-formed UTF-8.
about: RFC 6455 requires text frames to carry valid UTF-8, and BlitzMax's
decoder is permissive, so invalid sequences are rejected here rather than
turned into replacement characters that would then parse as legal JSON.
End Rem
Function ConvexIsValidUtf8:Int(data:Byte[], count:Int)
	Local index:Int = 0
	While index < count
		Local lead:Int = data[index]
		If lead < $80 Then
			index :+ 1
			Continue
		End If
		Local extra:Int = 0
		Local codepoint:Int = 0
		If lead >= $C2 And lead <= $DF Then
			extra = 1
			codepoint = lead & $1F
		ElseIf lead >= $E0 And lead <= $EF Then
			extra = 2
			codepoint = lead & $0F
		ElseIf lead >= $F0 And lead <= $F4 Then
			extra = 3
			codepoint = lead & $07
		Else
			' $80-$C1 are continuation bytes or overlong two-byte leads.
			Return False
		End If
		If index + extra >= count Then
			Return False
		End If
		For Local following:Int = 1 To extra
			Local continuation:Int = data[index + following]
			If continuation < $80 Or continuation > $BF Then
				Return False
			End If
			codepoint = (codepoint Shl 6) | (continuation & $3F)
		Next
		If extra = 2 And codepoint < $800 Then
			Return False
		End If
		If extra = 3 And codepoint < $10000 Then
			Return False
		End If
		If codepoint > $10FFFF Then
			Return False
		End If
		If codepoint >= $D800 And codepoint <= $DFFF Then
			' Surrogate halves are not scalar values and must not be encoded.
			Return False
		End If
		index :+ extra + 1
	Wend
	Return True
End Function

Rem
bbdoc: A Convex deployment address split into the parts a connection needs.
about: Convex publishes one https origin. HTTP calls post to it directly and
Live upgrades the same origin to wss, so both transports resolve the host,
port, and TLS decision through this single parser.
End Rem
Type TConvexEndpoint

	Field host:String
	Field port:Int
	Field useTls:Int
	Field origin:String

	Rem
	bbdoc: Parses a deployment URL, rejecting anything that is not http or https.
	End Rem
	Function Parse:TConvexEndpoint(url:String)
		Local this:TConvexEndpoint = New TConvexEndpoint
		Local rest:String
		If url.StartsWith("https://") Then
			this.useTls = True
			this.port = 443
			rest = url[8..]
		ElseIf url.StartsWith("http://") Then
			this.useTls = False
			this.port = 80
			rest = url[7..]
		Else
			Throw TConvexError.Protocol("a Convex deployment URL must use http or https")
		End If
		' Anything after the authority is a path; a deployment URL carries none,
		' and silently ignoring one would send calls somewhere unexpected.
		Local slash:Int = rest.Find("/")
		If slash >= 0 Then
			Local trailing:String = rest[slash..]
			If trailing <> "/" Then
				Throw TConvexError.Protocol("a Convex deployment URL must not carry a path")
			End If
			rest = rest[..slash]
		End If
		Local colon:Int = rest.FindLast(":")
		If colon > 0 Then
			Local portText:String = rest[colon + 1..]
			Local parsed:Int = portText.ToInt()
			If parsed <= 0 Or parsed > 65535 Or ("" + parsed) <> portText Then
				Throw TConvexError.Protocol("a Convex deployment URL has an invalid port")
			End If
			this.port = parsed
			rest = rest[..colon]
		End If
		If rest.length = 0 Then
			Throw TConvexError.Protocol("a Convex deployment URL has no host")
		End If
		this.host = rest
		this.origin = url
		If this.origin.EndsWith("/") Then
			this.origin = this.origin[..this.origin.length - 1]
		End If
		Return this
	End Function

	Rem
	bbdoc: The Host header value, omitting the port when it is the default.
	End Rem
	Method Authority:String()
		If (useTls And port = 443) Or ((Not useTls) And port = 80) Then
			Return host
		End If
		Return host + ":" + port
	End Method

End Type

Rem
bbdoc: Process-wide mbed TLS material: entropy, a seeded generator, and roots.
about: Seeding is expensive and the trust store is large, so both are created
once. The generator is also the source of WebSocket keys and masks, which keeps
the client from inventing a second, weaker randomness path.
End Rem
Type TConvexCrypto

	Global instance:TConvexCrypto

	Field entropy:TEntropyContext
	Field random:TRandContext
	Field roots:TX509Cert
	Field rootsLoaded:Int

	Function Shared:TConvexCrypto()
		If instance Then
			Return instance
		End If
		Local this:TConvexCrypto = New TConvexCrypto
		this.entropy = New TEntropyContext.Create()
		this.random = New TRandContext.Create()
		Local seeded:Int = this.random.Seed(EntropyFunc, this.entropy)
		If seeded <> 0 Then
			Throw TConvexError.Transport("could not seed the TLS random generator: " + MBEDTLSError(seeded))
		End If
		instance = this
		Return instance
	End Function

	Rem
	bbdoc: Fills the first @count bytes of @buffer with generator output.
	End Rem
	Method Fill(buffer:Byte[], count:Int)
		Local produced:Int = convex_ctr_drbg_random(random.contextPtr, buffer, Size_T(count))
		If produced <> 0 Then
			Throw TConvexError.Transport("random generator failed: " + MBEDTLSError(produced))
		End If
	End Method

	Rem
	bbdoc: Loads the CA bundle once, on the first TLS connection.
	End Rem
	Method TrustStore:TX509Cert()
		If rootsLoaded Then
			Return roots
		End If
		Local bundle:String = ConvexEnv("CONVEX_CA_BUNDLE")
		If bundle.length = 0 Then
			bundle = "/etc/ssl/certs/ca-certificates.crt"
		End If
		roots = New TX509Cert.Create()
		' Parse is permissive: a positive result counts certificates it could
		' not read, and a negative result means it read none at all.
		Local failed:Int = roots.ParseFile(bundle)
		If failed < 0 Then
			Throw TConvexError.Transport("could not load the CA bundle " + bundle + ": " + MBEDTLSError(failed))
		End If
		rootsLoaded = True
		Return roots
	End Method

End Type

Rem
bbdoc: One TCP connection, optionally wrapped in TLS.
about: Reads and writes are non-blocking and driven by readiness polling, so a
single absolute deadline bounds a whole operation regardless of how the peer
paces its bytes.
End Rem
Type TConvexSocket

	Field net:TNetContext
	Field ssl:TSSLContext
	Field config:TSSLConfig
	Field scratch:Byte[]
	Field host:String
	Field open:Int
	Field peerClosed:Int

	Rem
	bbdoc: Connects to @host:@port, negotiating TLS when @useTls is true.
	End Rem
	Function Connect:TConvexSocket(host:String, port:Int, useTls:Int, deadline:TConvexDeadline)
		Local this:TConvexSocket = New TConvexSocket
		this.host = host
		this.scratch = New Byte[CONVEX_IO_CHUNK_BYTES]
		this.net = New TNetContext.Create()
		' Name resolution and the TCP handshake are the one step mbed TLS does
		' not expose incrementally; they are bounded by the operating system's
		' resolver and connect timeouts rather than by this deadline. Every
		' later step is bounded by the deadline.
		Local connected:Int = this.net.Connect(host, "" + port, MBEDTLS_NET_PROTO_TCP)
		If connected <> 0 Then
			Throw TConvexError.Transport("could not connect to " + host + ":" + port + ": " + MBEDTLSError(connected))
		End If
		If this.net.SetNonBlock() <> 0 Then
			this.net.Free()
			Throw TConvexError.Transport("could not make the connection non-blocking")
		End If
		this.open = True
		If useTls Then
			this.StartTls(deadline)
		End If
		Return this
	End Function

	Rem
	bbdoc: Wraps the live socket in a verified TLS session.
	End Rem
	Method StartTls(deadline:TConvexDeadline)
		Local crypto:TConvexCrypto = TConvexCrypto.Shared()
		config = New TSSLConfig.Create()
		Local defaults:Int = config.Defaults(MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT)
		If defaults <> 0 Then
			Throw TConvexError.Transport("TLS configuration failed: " + MBEDTLSError(defaults))
		End If
		config.RNG(RandomFunc, crypto.random)
		' The client preset already requires verification; supplying the roots
		' is what makes that requirement satisfiable.
		config.CaChain(crypto.TrustStore(), Null)
		ssl = New TSSLContext.Create()
		Local prepared:Int = ssl.Setup(config)
		If prepared <> 0 Then
			Throw TConvexError.Transport("TLS setup failed: " + MBEDTLSError(prepared))
		End If
		' Without this the handshake sends no SNI and the certificate is never
		' checked against the name we asked for, which is the point of verifying
		' it at all. The wrapper has no binding for it, so call mbed TLS.
		Local encodedHost:Byte Ptr = host.ToUTF8String()
		Local named:Int = convex_ssl_set_hostname(ssl.contextPtr, encodedHost)
		MemFree(encodedHost)
		If named <> 0 Then
			Throw TConvexError.Transport("could not set the TLS server name: " + MBEDTLSError(named))
		End If
		ssl.SetBio(net, NetSend, NetRecv, Null)
		Repeat
			Local state:Int = ssl.Handshake()
			If state = 0 Then
				Exit
			End If
			If state <> MBEDTLS_ERR_SSL_WANT_READ And state <> MBEDTLS_ERR_SSL_WANT_WRITE Then
				Throw TConvexError.Transport("TLS handshake failed: " + MBEDTLSError(state))
			End If
			Local direction:Int = MBEDTLS_NET_POLL_READ
			If state = MBEDTLS_ERR_SSL_WANT_WRITE Then
				direction = MBEDTLS_NET_POLL_WRITE
			End If
			WaitReady(direction, deadline, "TLS handshake")
		Forever
		Local verified:Int = ssl.GetVerifyResult()
		If verified <> 0 Then
			Throw TConvexError.Transport("TLS certificate verification failed with flags " + verified)
		End If
	End Method

	Rem
	bbdoc: Waits for readiness in short slices, failing on the absolute deadline.
	End Rem
	Method WaitReady(direction:Int, deadline:TConvexDeadline, operation:String)
		Local remaining:Int = deadline.RemainingMs()
		If remaining <= 0 Then
			Throw TConvexError.Transport(operation + " exceeded its absolute deadline")
		End If
		' Slice the wait so cooperative work still runs and so one select call
		' cannot outlive the deadline by more than a slice.
		If remaining > 25 Then
			remaining = 25
		End If
		Local ready:Int = net.Poll(direction, remaining)
		If ready < 0 Then
			Throw TConvexError.Transport(operation + " could not poll the connection")
		End If
		ConvexIdle()
	End Method

	Rem
	bbdoc: True when a read would not block right now.
	End Rem
	Method Readable:Int(timeoutMs:Int)
		If Not open Then
			Return False
		End If
		' A TLS record already sitting in mbed TLS's buffer is invisible to the
		' socket, so ask the library before asking the kernel.
		If ssl And ssl.GetBytesAvail() > 0 Then
			Return True
		End If
		If net.Poll(MBEDTLS_NET_POLL_READ, timeoutMs) <= 0 Then
			Return False
		End If
		Return True
	End Method

	Rem
	bbdoc: Appends whatever is readable to @buffer without exceeding @limit total bytes.
	returns: bytes appended, 0 when the read would block, or -1 once the peer closed.
	End Rem
	Method ReadInto:Int(buffer:TConvexBuffer, limit:Int)
		If Not open Then
			Throw TConvexError.Transport("connection is closed")
		End If
		Local room:Int = limit - buffer.length
		If room <= 0 Then
			Throw TConvexError.Transport("peer sent more than the bounded " + limit + " bytes")
		End If
		If room > CONVEX_IO_CHUNK_BYTES Then
			room = CONVEX_IO_CHUNK_BYTES
		End If
		Local received:Int
		If ssl Then
			received = ssl.Read(scratch, Size_T(room))
		Else
			received = net.Recv(scratch, Size_T(room))
		End If
		If received > 0 Then
			buffer.AppendBytes(scratch, received)
			Return received
		End If
		If received = 0 Or received = MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY Then
			peerClosed = True
			Return -1
		End If
		If received = MBEDTLS_ERR_SSL_WANT_READ Or received = MBEDTLS_ERR_SSL_WANT_WRITE Then
			Return 0
		End If
		Throw TConvexError.Transport("read failed: " + MBEDTLSError(received))
	End Method

	Rem
	bbdoc: Writes the first @count bytes of @payload, or fails on the deadline.
	End Rem
	Method WriteAll(payload:Byte[], count:Int, deadline:TConvexDeadline)
		If Not open Then
			Throw TConvexError.Transport("connection is closed")
		End If
		Local offset:Int = 0
		While offset < count
			If deadline.Expired() Then
				Throw TConvexError.Transport("write exceeded its absolute deadline")
			End If
			Local sent:Int
			If ssl Then
				sent = ssl.Write(Varptr payload[offset], Size_T(count - offset))
			Else
				sent = net.Send(Varptr payload[offset], Size_T(count - offset))
			End If
			If sent > 0 Then
				offset :+ sent
				Continue
			End If
			If sent = MBEDTLS_ERR_SSL_WANT_READ Then
				WaitReady(MBEDTLS_NET_POLL_READ, deadline, "write")
				Continue
			End If
			If sent = MBEDTLS_ERR_SSL_WANT_WRITE Or sent = 0 Then
				WaitReady(MBEDTLS_NET_POLL_WRITE, deadline, "write")
				Continue
			End If
			Throw TConvexError.Transport("write failed: " + MBEDTLSError(sent))
		Wend
	End Method

	Method WriteText(text:String, deadline:TConvexDeadline)
		Local outgoing:TConvexBuffer = TConvexBuffer.Create(text.length + 32)
		outgoing.AppendString(text)
		WriteAll(outgoing.data, outgoing.length, deadline)
	End Method

	Rem
	bbdoc: Tears the connection down without waiting for the peer.
	about: A TLS close-notify is attempted once and never retried: a peer that
	stalls halfway through a record must not be able to hold a close open.
	End Rem
	Method Close()
		If Not open Then
			Return
		End If
		open = False
		If ssl Then
			ssl.CloseNotify()
		End If
		net.Free()
	End Method

End Type
