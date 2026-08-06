using Base64
using JSON3
using SHA
using Sockets
using ConvexRuntime

const Adapter = ConvexRuntime.AdapterProgram
const Client = ConvexRuntime.Convex

function read_exact(io::IO, count::Int)
    bytes = Vector{UInt8}(undef, count)
    read!(io, bytes)
    return bytes
end

function read_headers(socket)
    bytes = UInt8[]
    marker = UInt8[0x0d, 0x0a, 0x0d, 0x0a]
    while length(bytes) < 16 * 1024
        push!(bytes, read(socket, UInt8))
        length(bytes) >= 4 && bytes[(end-3):end] == marker && return String(bytes)
    end
    error("oversized fixture headers")
end

function consume_http_request(socket, headers = read_headers(socket))
    match_result = match(r"(?im)^Content-Length:\s*(\d+)", headers)
    content_length = isnothing(match_result) ? 0 : parse(Int, match_result.captures[1])
    content_length == 0 || read_exact(socket, content_length)
end

function send_http_response(socket, value)
    body =
        JSON3.write(Dict("status" => "success", "value" => value, "logLines" => String[]))
    write(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" *
        "Content-Length: $(ncodeunits(body))\r\nConnection: close\r\n\r\n",
        body,
    )
    flush(socket)
end

# Drive the exact compiled adapter module through real TCP HTTP requests and a
# malformed NDJSON line before close. This records the output-pump, JSON, HTTP,
# function-error isolation, and bounded command-loop specializations.
http_listener = listen(ip"127.0.0.1", 0)
http_port = getsockname(http_listener)[2]
http_server = @async begin
    for value in (Dict("count" => 0.0), Dict("applied" => true), Dict("acted" => true))
        socket = accept(http_listener)
        try
            consume_http_request(socket)
            send_http_response(socket, value)
        finally
            close(socket)
        end
    end
    close(http_listener)
end

old_url = get(ENV, "CONVEX_URL", nothing)
ENV["CONVEX_URL"] = "http://127.0.0.1:$(http_port)"
adapter_input = IOBuffer(
    "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n" *
    "{malformed json}\n" *
    "{\"id\":\"query\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n" *
    "{\"id\":\"mutation\",\"op\":\"mutation\",\"path\":\"demo:increment\",\"args\":{}}\n" *
    "{\"id\":\"action\",\"op\":\"action\",\"path\":\"demo:action\",\"args\":{}}\n" *
    "{\"id\":\"close\",\"op\":\"close\"}\n",
)
try
    Adapter.run_adapter(adapter_input, IOBuffer())
finally
    isnothing(old_url) ? delete!(ENV, "CONVEX_URL") : (ENV["CONVEX_URL"] = old_url)
end
wait(http_server)

function read_client_frame(socket)
    header = read_exact(socket, 2)
    opcode = header[1] & 0x0f
    length_code = Int(header[2] & 0x7f)
    payload_length = if length_code < 126
        length_code
    elseif length_code == 126
        bytes = read_exact(socket, 2)
        Int(UInt16(bytes[1]) << 8 | UInt16(bytes[2]))
    else
        bytes = read_exact(socket, 8)
        foldl((value, byte) -> value << 8 | UInt64(byte), bytes; init = UInt64(0)) |> Int
    end
    mask = read_exact(socket, 4)
    payload = read_exact(socket, payload_length)
    for index in eachindex(payload)
        payload[index] = xor(payload[index], mask[(index-1)%4+1])
    end
    return opcode, payload
end

function read_client_json(socket)
    while true
        opcode, payload = read_client_frame(socket)
        opcode == 0x01 && return JSON3.read(String(payload))
    end
end

function server_handshake(socket, headers = read_headers(socket))
    key_match = match(r"(?im)^Sec-WebSocket-Key:\s*([^\r]+)", headers)
    isnothing(key_match) && error("fixture client omitted WebSocket key")
    accept = base64encode(
        sha1(strip(key_match.captures[1]) * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"),
    )
    write(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" *
        "Connection: Upgrade\r\nSec-WebSocket-Accept: $(accept)\r\n\r\n",
    )
    flush(socket)
end

function server_frame(opcode::Integer, payload::Vector{UInt8}; final = true)
    first = UInt8(opcode) | (final ? 0x80 : 0x00)
    if length(payload) <= 125
        return vcat(UInt8[first, UInt8(length(payload))], payload)
    end
    length(payload) <= 0xffff || error("fixture payload is too large")
    return vcat(
        UInt8[first, 126, UInt8(length(payload) >> 8), UInt8(length(payload) & 0xff)],
        payload,
    )
end

timestamp = base64encode(UInt8[(UInt64(1) >> (8 * offset)) & 0xff for offset = 0:7])
live_listener = listen(ip"127.0.0.1", 0)
live_port = getsockname(live_listener)[2]
live_server = @async begin
    socket = accept(live_listener)
    close(live_listener)
    try
        server_handshake(socket)
        read_client_json(socket) # Connect
        add = read_client_json(socket)
        query_id = Int(add["modifications"][1]["queryId"])
        transition = Dict(
            "type" => "Transition",
            "startVersion" => Dict(
                "querySet" => 0,
                "identity" => 0,
                "ts" => base64encode(zeros(UInt8, 8)),
            ),
            "endVersion" => Dict("querySet" => 1, "identity" => 0, "ts" => timestamp),
            "modifications" => [
                Dict(
                    "type" => "QueryUpdated",
                    "queryId" => query_id,
                    "value" => Dict("count" => 0),
                    "logLines" => ["héllo"],
                    "journal" => nothing,
                ),
            ],
        )
        payload = Vector{UInt8}(JSON3.write(transition))
        midpoint = length(payload) ÷ 2
        write(socket, server_frame(0x01, payload[1:midpoint]; final = false))
        write(socket, server_frame(0x09, UInt8[0x70]))
        write(socket, server_frame(0x00, payload[(midpoint+1):end]))
        flush(socket)
        remove = read_client_json(socket)
        remove["modifications"][1]["type"] == "Remove" ||
            error("fixture expected Remove")
    finally
        close(socket)
    end
end

# Drive the exact shared client module through a real WebSocket handshake,
# fragmented UTF-8 transition, control frame, Add, update, and Remove.
# Use a JSON3.Object args value so the stripped image records the same
# canonicalize → Dict{String,Any} Subscribe path the adapter harness uses.
live_client = Client.Client("http://127.0.0.1:$(live_port)")
subscription = Client.subscribe(
    live_client,
    "demo:state",
    JSON3.read("{\"room\":\"precompile\",\"nested\":{\"k\":\"v\"},\"n\":1,\"ok\":true}"),
)
update = Client.next_update(subscription; timeout = 5)
update.error === nothing || throw(update.error)
Client.unsubscribe!(subscription)
Client.close!(live_client)
wait(live_server)

# Drive the exact adapter Subscribe path the hosted harness uses: NDJSON args
# decode to JSON3.Object, command_args canonicalizes them, then the Live owner
# sends Connect + Add over a real socket. Without this, --strip-ir drops the
# adapter-only Subscribe specialization that Dict-literal client calls miss.
adapter_live_listener = listen(ip"127.0.0.1", 0)
adapter_live_port = getsockname(adapter_live_listener)[2]
adapter_live_transition_sent = Channel{Nothing}(1)
adapter_live_server = @async begin
    socket = accept(adapter_live_listener)
    close(adapter_live_listener)
    try
        server_handshake(socket)
        read_client_json(socket) # Connect
        add = read_client_json(socket)
        query_id = Int(add["modifications"][1]["queryId"])
        add_args = add["modifications"][1]["args"][1]
        add_args["room"] == "adapter-precompile" ||
            error("adapter subscribe args lost room")
        add_args["nested"]["k"] == "v" || error("adapter subscribe nested args lost")
        transition = Dict(
            "type" => "Transition",
            "startVersion" =>
                Dict("querySet" => 0, "identity" => 0, "ts" => "AAAAAAAAAAA="),
            "endVersion" => Dict("querySet" => 1, "identity" => 0, "ts" => timestamp),
            "modifications" => [
                Dict(
                    "type" => "QueryUpdated",
                    "queryId" => query_id,
                    "value" => Dict("count" => 0.0),
                    "logLines" => String[],
                    "journal" => nothing,
                ),
            ],
        )
        write(socket, server_frame(0x01, Vector{UInt8}(JSON3.write(transition))))
        flush(socket)
        # Wait until the complete Transition frame is flushed before the
        # adapter's scripted unsubscribe is allowed to retire this socket.
        put!(adapter_live_transition_sent, nothing)
        remove = read_client_json(socket)
        remove["modifications"][1]["type"] == "Remove" ||
            error("adapter live expected Remove")
    finally
        close(socket)
    end
end

old_adapter_live_url = get(ENV, "CONVEX_URL", nothing)
ENV["CONVEX_URL"] = "http://127.0.0.1:$(adapter_live_port)"
adapter_live_input = Pipe()
Base.link_pipe!(
    adapter_live_input;
    reader_supports_async = true,
    writer_supports_async = true,
)
adapter_live_output_pipe = Pipe()
Base.link_pipe!(
    adapter_live_output_pipe;
    reader_supports_async = true,
    writer_supports_async = true,
)
adapter_live_output_text = IOBuffer()
adapter_live_update_seen = Channel{Nothing}(1)
adapter_live_output_reader = @async begin
    while !eof(adapter_live_output_pipe.out)
        line = readline(adapter_live_output_pipe.out)
        write(adapter_live_output_text, line, '\n')
        occursin("\"type\":\"subscription\"", line) &&
            put!(adapter_live_update_seen, nothing)
    end
end
adapter_live_task =
    @async Adapter.run_adapter(adapter_live_input.out, adapter_live_output_pipe.in)
try
    write(
        adapter_live_input.in,
        "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n" *
        "{\"id\":\"sub\",\"op\":\"subscribe\",\"subscriptionId\":\"s1\"," *
        "\"path\":\"demo:state\"," *
        "\"args\":{\"room\":\"adapter-precompile\",\"nested\":{\"k\":\"v\"},\"n\":1,\"ok\":true}}\n",
    )
    flush(adapter_live_input.in)
    take!(adapter_live_transition_sent)
    # Wait for the relay to publish the update before allowing unsubscribe and
    # close to retire the subscription and its output queue.
    take!(adapter_live_update_seen)
    write(
        adapter_live_input.in,
        "{\"id\":\"unsub\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s1\"}\n" *
        "{\"id\":\"close\",\"op\":\"close\"}\n",
    )
    flush(adapter_live_input.in)
    close(adapter_live_input.in)
    wait(adapter_live_task)
finally
    isopen(adapter_live_input.in) && close(adapter_live_input.in)
    wait(adapter_live_task)
    isopen(adapter_live_output_pipe.in) && close(adapter_live_output_pipe.in)
    wait(adapter_live_output_reader)
    isnothing(old_adapter_live_url) ? delete!(ENV, "CONVEX_URL") :
    (ENV["CONVEX_URL"] = old_adapter_live_url)
end
wait(adapter_live_server)
adapter_live_text = String(take!(adapter_live_output_text))
occursin("\"type\":\"ready\"", adapter_live_text) || error("adapter live omitted ready")
occursin("\"type\":\"ack\"", adapter_live_text) ||
    error("adapter live omitted subscribe ack")
occursin("\"type\":\"subscription\"", adapter_live_text) ||
    error("adapter live omitted subscription")
occursin("\"type\":\"closed\"", adapter_live_text) || error("adapter live omitted close")

function connect_with_deadline(port; timeout = 5.0)
    deadline = time() + timeout
    while true
        try
            return connect(ip"127.0.0.1", port)
        catch error
            time() >= deadline && rethrow(error)
            sleep(0.002)
        end
    end
end

# Exercise the real packaged TCP entrypoint. Splitting the first command across
# writes records the partial-NDJSON path, while the malformed middle line proves
# that one bad command does not prevent the following close from being handled.
adapter_reservation = listen(ip"127.0.0.1", 0)
adapter_port = getsockname(adapter_reservation)[2]
close(adapter_reservation)
old_listen = get(ENV, "ADAPTER_LISTEN", nothing)
ENV["ADAPTER_LISTEN"] = "127.0.0.1:$(adapter_port)"
adapter_main_task = @async ConvexRuntime.adapter_main()
adapter_socket = connect_with_deadline(adapter_port)
try
    hello = "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"
    split_at = ncodeunits(hello) ÷ 2
    write(adapter_socket, codeunits(hello)[1:split_at])
    flush(adapter_socket)
    write(adapter_socket, codeunits(hello)[(split_at+1):end])
    write(adapter_socket, "{malformed json}\n")
    write(adapter_socket, "{\"id\":\"close\",\"op\":\"close\"}\n")
    flush(adapter_socket)
    adapter_output = read(adapter_socket, String)
    occursin("\"type\":\"ready\"", adapter_output) ||
        error("TCP adapter precompile omitted ready")
    occursin("\"type\":\"closed\"", adapter_output) ||
        error("TCP adapter precompile omitted close")
finally
    close(adapter_socket)
    isnothing(old_listen) ? delete!(ENV, "ADAPTER_LISTEN") :
    (ENV["ADAPTER_LISTEN"] = old_listen)
end
fetch(adapter_main_task) == 0 || error("TCP adapter precompile failed")

# Exercise real linked PipeEndpoints as used by `docker run -i`. An explicit
# signature did not record dynamic pipe iteration and deprecation paths deeply
# enough once IR was stripped, so this must be an executed command loop.
pipe_input = Pipe()
pipe_output = Pipe()
Base.link_pipe!(pipe_input; reader_supports_async = true, writer_supports_async = true)
Base.link_pipe!(pipe_output; reader_supports_async = true, writer_supports_async = true)
pipe_adapter_task = @async Adapter.run_adapter(pipe_input.out, pipe_output.in)
write(pipe_input.in, "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n")
write(pipe_input.in, "{\"id\":\"close\",\"op\":\"close\"}\n")
flush(pipe_input.in)
close(pipe_input.in)
wait(pipe_adapter_task)
close(pipe_output.in)
pipe_output_text = read(pipe_output.out, String)
occursin("\"type\":\"ready\"", pipe_output_text) ||
    error("pipe adapter precompile omitted ready")
occursin("\"type\":\"closed\"", pipe_output_text) ||
    error("pipe adapter precompile omitted close")
close(pipe_input.out)
close(pipe_output.out)

# BuildKit also supplies EOF stdin while recording this workload. Run the
# packaged branch itself and retain the first dynamic warning path diagnosed
# from the previous stripped candidate.
ConvexRuntime.adapter_main() == 0 || error("stdin adapter precompile failed")
# Docker's launcher can expose stdin as an IOStream and stdout as a
# PipeEndpoint. Retain both concrete stream combinations so the stripped
# executable does not miss its real NDJSON entrypoint specialization.
precompile(Adapter.run_adapter, (Base.IOStream, Base.PipeEndpoint))
precompile(Adapter.run_adapter, (Base.IOStream, Base.IOStream))
precompile(Adapter.run_adapter, (Base.PipeEndpoint, Base.PipeEndpoint))
# A hosted WSS failure reaches the adapter's structured error event path after
# the owner has reported the transport error. Retain both id shapes used by
# command and subscription failures so the stripped runtime can report that
# error instead of terminating with a MissingCodeError.
precompile(Adapter.failure, (Adapter.OutputPump, String, Client.ConvexError))
precompile(Adapter.failure, (Adapter.OutputPump, Nothing, Client.ConvexError))
precompile(Adapter.serialise_error, (Client.ConvexError,))
# Keep HTTP.jl's generic WebSocket wrapper and its GET upgrade dispatch in the
# stripped image. The deterministic WSS fixture exercises the same API, but
# PackageCompiler can otherwise leave this generic path to first use in the
# final application.
precompile(Client.HTTP.WebSockets.open, (Function, String))
precompile(Client.HTTP.open, (Function, String, String, Vector{Pair{String,String}}))
precompile(Base._depwarn, (Any, Any, Bool))

function fixture_transition(
    query_id,
    count,
    start_query_set,
    end_query_set,
    start_ts,
    end_ts,
)
    return Dict(
        "type" => "Transition",
        "startVersion" => Dict(
            "querySet" => start_query_set,
            "identity" => 0,
            "ts" => base64encode(
                UInt8[(UInt64(start_ts) >> (8 * offset)) & 0xff for offset = 0:7],
            ),
        ),
        "endVersion" => Dict(
            "querySet" => end_query_set,
            "identity" => 0,
            "ts" => base64encode(
                UInt8[(UInt64(end_ts) >> (8 * offset)) & 0xff for offset = 0:7],
            ),
        ),
        "modifications" => [
            Dict(
                "type" => "QueryUpdated",
                "queryId" => query_id,
                "value" => Dict("count" => count),
                "logLines" => String[],
                "journal" => nothing,
            ),
        ],
    )
end

# Run the exact canonical example rather than a test-only translation. One
# listener handles its Live socket and both HTTP calls, preserving the real
# start-Live-before-mutation ordering and compiling the complete 0 -> 1 path.
example_listener = listen(ip"127.0.0.1", 0)
example_port = getsockname(example_listener)[2]
example_mutated = Channel{Nothing}(1)
example_handlers = Task[]
example_server = @async begin
    for _ = 1:3
        socket = accept(example_listener)
        handler = @async try
            headers = read_headers(socket)
            if occursin("upgrade: websocket", lowercase(headers))
                server_handshake(socket, headers)
                read_client_json(socket) # Connect
                add = read_client_json(socket)
                query_id = Int(add["modifications"][1]["queryId"])
                write(
                    socket,
                    server_frame(
                        0x01,
                        Vector{UInt8}(
                            JSON3.write(fixture_transition(query_id, 0, 0, 1, 0, 1)),
                        ),
                    ),
                )
                flush(socket)
                take!(example_mutated)
                write(
                    socket,
                    server_frame(
                        0x01,
                        Vector{UInt8}(
                            JSON3.write(fixture_transition(query_id, 1, 1, 1, 1, 2)),
                        ),
                    ),
                )
                flush(socket)
                remove = read_client_json(socket)
                remove["modifications"][1]["type"] == "Remove" ||
                    error("example fixture expected Remove")
            else
                consume_http_request(socket, headers)
                if occursin("POST /api/query ", headers)
                    send_http_response(socket, Dict("count" => 0.0))
                elseif occursin("POST /api/mutation ", headers)
                    send_http_response(
                        socket,
                        Dict("applied" => true, "state" => Dict("count" => 1.0)),
                    )
                    put!(example_mutated, nothing)
                else
                    error("unexpected example fixture request")
                end
            end
        finally
            close(socket)
        end
        push!(example_handlers, handler)
    end
    close(example_listener)
    foreach(wait, example_handlers)
end

old_example_url = get(ENV, "CONVEX_URL", nothing)
old_example_room = get(ENV, "EXAMPLE_ROOM", nothing)
ENV["CONVEX_URL"] = "http://127.0.0.1:$(example_port)"
ENV["EXAMPLE_ROOM"] = "precompile-example"
try
    example_status = redirect_stdout(devnull) do
        ConvexRuntime.example_main()
    end
    example_status == 0 || error("canonical example precompile failed")
finally
    isnothing(old_example_url) ? delete!(ENV, "CONVEX_URL") :
    (ENV["CONVEX_URL"] = old_example_url)
    isnothing(old_example_room) ? delete!(ENV, "EXAMPLE_ROOM") :
    (ENV["EXAMPLE_ROOM"] = old_example_room)
end
wait(example_server)

# Reuse the deterministic test-only identity from the language-local WSS test.
# Executing a real Julia TLS server here records HTTP's WSS handshake and the
# production OpenSSL.SSLStream one-shot read before all compiler IR is removed.
fixture_source = read(joinpath(@__DIR__, "..", "tests", "runtests.jl"), String)
function fixture_pem(name)
    matched = match(Regex("const $(name) = \"\"\"(.*?)\"\"\"", "s"), fixture_source)
    isnothing(matched) && error("missing $(name) in deterministic WSS fixture")
    return matched.captures[1]
end

tls_fixture_dir = mktempdir()
tls_cert_path = joinpath(tls_fixture_dir, "cert.pem")
tls_key_path = joinpath(tls_fixture_dir, "key.pem")
write(tls_cert_path, fixture_pem("TEST_TLS_CERT"))
write(tls_key_path, fixture_pem("TEST_TLS_KEY"))
tls_errors = Channel{Any}(1)
tls_server = Client.HTTP.WebSockets.listen!(
    ip"127.0.0.1",
    0;
    sslconfig = Client.HTTP.SSLConfig(tls_cert_path, tls_key_path),
    suppress_close_error = true,
) do websocket
    try
        JSON3.read(String(Client.HTTP.WebSockets.receive(websocket))) # Connect
        add = JSON3.read(String(Client.HTTP.WebSockets.receive(websocket)))
        query_id = Int(add["modifications"][1]["queryId"])
        Client.HTTP.WebSockets.send(
            websocket,
            JSON3.write(fixture_transition(query_id, 1, 0, 1, 0, 1)),
        )
        remove = JSON3.read(String(Client.HTTP.WebSockets.receive(websocket)))
        remove["modifications"][1]["type"] == "Remove" ||
            error("WSS precompile expected Remove")
        put!(tls_errors, nothing)
    catch error
        put!(tls_errors, error)
    end
end
tls_port = getsockname(tls_server.listener.server)[2]
old_roots = get(ENV, "JULIA_SSL_CA_ROOTS_PATH", nothing)
old_no_verify = get(ENV, "JULIA_SSL_NO_VERIFY_HOSTS", nothing)
ENV["JULIA_SSL_CA_ROOTS_PATH"] = tls_cert_path
ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = "127.0.0.1"

# WSS and HTTPS share OpenSSL transport but drive different HTTP.jl call
# graphs. Exercise a real TLS POST through the public query API so the stripped
# runtime retains request writing, response parsing, and certificate cleanup.
https_server = Client.HTTP.serve!(
    ip"127.0.0.1",
    0;
    sslconfig = Client.HTTP.SSLConfig(tls_cert_path, tls_key_path),
    verbose = false,
) do request
    request.target == "/api/query" || error("unexpected HTTPS precompile target")
    return Client.HTTP.Response(
        200,
        ["Content-Type" => "application/json"],
        JSON3.write(
            Dict(
                "status" => "success",
                "value" => Dict("count" => 1.0),
                "logLines" => String[],
            ),
        ),
    )
end
https_port = getsockname(https_server.listener.server)[2]
https_client = Client.Client("https://127.0.0.1:$(https_port)")
try
    https_result = Client.query(
        https_client,
        "demo:state",
        JSON3.read("{\"room\":\"precompile\",\"n\":1}"),
    )
    Client.whole_count(https_result.value["count"], "HTTPS precompile count") == 1 ||
        error("HTTPS precompile query returned an unexpected count")
finally
    Client.close!(https_client)
    Client.HTTP.forceclose(https_server)
end

tls_client = Client.Client("https://127.0.0.1:$(tls_port)")
try
    # Hosted Live always arrives as wss:// with adapter-normalized args. Record
    # that exact signature before PackageCompiler strips unused IR.
    tls_subscription = Client.subscribe(
        tls_client,
        "demo:state",
        JSON3.read("{\"room\":\"precompile-wss\",\"nested\":{\"k\":\"v\"},\"n\":1}"),
    )
    tls_update = Client.next_update(tls_subscription; timeout = 5)
    tls_update.error === nothing || throw(tls_update.error)
    Client.unsubscribe!(tls_subscription)
finally
    Client.close!(tls_client)
    Client.HTTP.forceclose(tls_server)
end
tls_error = take!(tls_errors)
tls_error === nothing || throw(tls_error)

# A successful WSS exchange does not compile transport-failure construction or
# recovery. Retire a second real TLS peer after Add and require the typed error
# to reach the same public subscription before bounded cleanup.
tls_failure_seen = Channel{Nothing}(1)
tls_failure_server = Client.HTTP.WebSockets.listen!(
    ip"127.0.0.1",
    0;
    sslconfig = Client.HTTP.SSLConfig(tls_cert_path, tls_key_path),
    suppress_close_error = true,
) do websocket
    try
        JSON3.read(String(Client.HTTP.WebSockets.receive(websocket))) # Connect
        JSON3.read(String(Client.HTTP.WebSockets.receive(websocket))) # Add
        put!(tls_failure_seen, nothing)
    finally
        Client.force_close!(websocket)
    end
end
tls_failure_port = getsockname(tls_failure_server.listener.server)[2]
tls_failure_client = Client.Client("https://127.0.0.1:$(tls_failure_port)")
try
    tls_failure_subscription = Client.subscribe(
        tls_failure_client,
        "demo:state",
        Dict("room" => "precompile-wss-failure"),
    )
    take!(tls_failure_seen)
    tls_failure_update = Client.next_update(tls_failure_subscription; timeout = 5)
    tls_failure_update.error isa Client.ConvexError ||
        error("WSS failure precompile omitted typed transport error")
    Client.unsubscribe!(tls_failure_subscription)
finally
    Client.close!(tls_failure_client)
    Client.HTTP.forceclose(tls_failure_server)
    isnothing(old_roots) ? delete!(ENV, "JULIA_SSL_CA_ROOTS_PATH") :
    (ENV["JULIA_SSL_CA_ROOTS_PATH"] = old_roots)
    isnothing(old_no_verify) ? delete!(ENV, "JULIA_SSL_NO_VERIFY_HOSTS") :
    (ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = old_no_verify)
end

# Run finalizers while PackageCompiler is still tracing. In particular,
# OpenSSL certificate/context frees must not first appear after IR is removed.
GC.gc(true)
GC.gc(true)
for resource_type in (
    Client.OpenSSL.BIO,
    Client.OpenSSL.SSL,
    Client.OpenSSL.SSLContext,
    Client.OpenSSL.X509Certificate,
    Client.OpenSSL.X509Store,
)
    precompile(Client.OpenSSL.free, (resource_type,))
end
precompile(Client.ConvexError, (Symbol, String, Nothing, Vector{String}))

# The example and adapter share this decoder, but retain an explicit
# mathematically-integral decimal specialization for the canonical example.
Client.whole_count(1.0, "precompile count") == 1 || error("whole_count precompile failed")

# Pin the concrete signatures hosted Subscribe must retain after IR stripping.
let
    sample_args = Dict{String,Any}(
        "room" => "pin",
        "nested" => Dict{String,Any}("k" => "v"),
        "n" => 1,
        "ok" => true,
        "list" => Any[1, true, nothing],
    )
    Client.canonicalize_args(sample_args)
    Client.canonicalize_args(Dict("room" => "pin"))
    Client.canonicalize_args(JSON3.read("{\"room\":\"pin\"}"))
    JSON3.write(Dict{String,Any}("path" => "demo:state", "args" => sample_args))
    JSON3.write(
        Dict{String,Any}(
            "type" => "ModifyQuerySet",
            "baseVersion" => 0,
            "newVersion" => 1,
            "modifications" => Any[Dict{String,Any}(
                "type" => "Add",
                "queryId" => 1,
                "udfPath" => "demo:state",
                "args" => Any[sample_args],
            ),],
        ),
    )
end
precompile(Client.subscribe, (Client.Client, String, Dict{String,Any}))
precompile(Client.query, (Client.Client, String, Dict{String,Any}))
precompile(Client.mutation, (Client.Client, String, Dict{String,Any}))
precompile(Client.action, (Client.Client, String, Dict{String,Any}))
precompile(Client.typed_error, (Any, Symbol))
precompile(Client.canonicalize_args, (Dict{String,Any},))
precompile(Client.canonicalize_args, (Dict{String,String},))
