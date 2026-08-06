using Test
using Base64
using JSON3
using SHA
using Sockets

include(joinpath(@__DIR__, "..", "Convex.jl"))
using .Convex
include(joinpath(@__DIR__, "conformance", "adapter.jl"))

const TEST_TIMEOUT = 6.0

@testset "unknown Live transport errors stay structured" begin
    error = Convex.typed_error(ErrorException("unretained transport detail"), :transport)
    @test error isa Convex.ConvexError
    @test error.kind == :transport
    @test error.message == "Live transport failure"
    @test error.logs == String[]
end

# Static test-only identity for the loopback WSS fixture. The matching private
# key never leaves this deterministic local test and is not a deployment secret.
const TEST_TLS_CERT = """-----BEGIN CERTIFICATE-----
MIIDGjCCAgKgAwIBAgIUCqktHPEpYkerX2za8O/5HNV9IGcwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDgwNTE5NDM0N1oXDTM2MDgw
MjE5NDM0N1owFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA3IOEfVmwYcH5a8dq5VtoK8suaMui9lZseb42T2zlqQOq
oAMwEIEi5yNHjHNomF4gzv+MZ2CdjgJV+1Q8LLDHfeNxgyujbZAtvOkiCr4HZ9Z8
IPAIxED21LyXuxA9VSozBOYOT8wsq1JkZINFGZO0pQR45jveV74eXY8yEtmKCRfJ
Hd2hAkTR+P7a8gg/QlZLNzhYZpIQbSMMJegVmbvqd09Tw2hGwTlGACxmPpDegCjk
amXuQC/RWILlOjSDtQVW+hHk8wqZIlnJWca0CENgIf+sb38gXQqJf2to5DaXa0/b
pOkCuQz1jjp0Ht1uzmp1xKKomV1MN+09a/kzL6oT+wIDAQABo2QwYjAdBgNVHQ4E
FgQU8OXhvNtCKVLSN1G9DuPgTu3s05kwHwYDVR0jBBgwFoAU8OXhvNtCKVLSN1G9
DuPgTu3s05kwDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMA0GCSqG
SIb3DQEBCwUAA4IBAQDCL9mJkXgcYkGRUvm9hqFikbWrGIy0xM4Atx6SG+ayKMNM
0WL4oHAHnDLGtavXD6x1irdR0YuWO0qkJ0r8Z1Vzwa1CY16njVSI3Zd2Da7O7oTq
HpyF73lCMh5qq2pJ+XWvw0u+CRXlLFLZw7/zXQX7ESoLnCKTqFrS35OxxuXQBO79
R+FvwHh5479YKKHUOiNe4DjgWAx/5OVivfjxujsHA14i8ktL+PWfvGX0QixHTWeG
pyj73w9MqBr7tbA5zZm4C1eIdOZzuDcCmUD/3xI0A0webShSfbvoyM29ozTrnS+p
gUMA7dTgU3fKg6kyGs9hkoWxSoJrz7gpbPDdUH20
-----END CERTIFICATE-----
"""

const TEST_TLS_KEY = """-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDcg4R9WbBhwflr
x2rlW2gryy5oy6L2Vmx5vjZPbOWpA6qgAzAQgSLnI0eMc2iYXiDO/4xnYJ2OAlX7
VDwssMd943GDK6NtkC286SIKvgdn1nwg8AjEQPbUvJe7ED1VKjME5g5PzCyrUmRk
g0UZk7SlBHjmO95Xvh5djzIS2YoJF8kd3aECRNH4/tryCD9CVks3OFhmkhBtIwwl
6BWZu+p3T1PDaEbBOUYALGY+kN6AKORqZe5AL9FYguU6NIO1BVb6EeTzCpkiWclZ
xrQIQ2Ah/6xvfyBdCol/a2jkNpdrT9uk6QK5DPWOOnQe3W7OanXEoqiZXUw37T1r
+TMvqhP7AgMBAAECggEAOlGsFgzE2a3X3bnRWxRIIiDrxrpogHbN3IrCSVI3EPKP
yx7ctNi6Vt/dOdeB554pViV+yA5kzNxwSfZ2rakZMYGYEUVWxRC3D/mmT6n/QmaW
0I06/FBkF1JDXK1IU0BEWvzO9yq7+5lgRLb07PVD9sqOgPF/dbwpwruu1g5jc9Cx
IwNlyANUsrPFe+qExQnfNqLy5E6gPvoT6xc5wHgWdmxkrxSOWDBqhm63JSAXfE6z
axuB9vcGEsC4NczqlIbO1e+Uei1ykbvX6h86pzm3z7tdLp5I8jrVsZ7KZCMU9mXM
9dqev0u26q+wKSzlP45f4oJU2FUncT+qLpcalJgbEQKBgQD9+/IxL8EwO3rFyJxS
FNnStNrgdgqUT5K+YEmssgslp/45UsyDst3V6Lqe8YcCK0s+1ACEHrMMWB+KBciR
+iScT6VgKX/QF5RGzde7FsXo5THkfGkgrFa4WJppNbLKiQg+LT2j8k6ZFQh1UP3H
qGHSii0D1CDjhXfAlG03a71HUQKBgQDeQ5Cp7bgAvXUS2tw4NyxXEAVujo9ZWlg3
bCt+nS2ziym9Y79nJYFVmLb9Q+g+Hg1DBAbx6Um1k954vo4/zB+XkZjM3kAtv4ys
S1twVjkWeRWyeW0povv/syNxxArc0itTTERKEA/pClhoJTrI2rKl2++lP4Bl+TZ3
IS99113riwKBgQDnr1ecJMre+7MgDsMCYUDeY9ox3ZwC9J+RCHbMkVF31Uoj8nLb
RGP2SKlMaljU0rd+JZge7X45KX4DwwjWmM+iw0jBcrnEEm5RNF6xrLF2pPShUBf6
FRu6aCDbDn/9H4mkZlKPZm7qV/RySCJoaiJqE1/C2VPzGIJH613Bq4drMQKBgHkM
2UQDKRyWEqYDNr8TJX4BRsQQtnfWoYcFzaZ2mkZXu5LfOYZGwerJcpf7HQh/u39N
OS8VfER9VUPznGuYk3gsHsktHk0MLuRDYniLLSpVJgD+6vorPw3jFaHHQJdFi70h
I2wm1VN5g+6soBh2K6fzYdBhBmADW6uEEmZ6HjfDAoGBANsIKeYM8+tWvx7NOIzy
LdHlpyVbXyCNZOACRgGZT8wQ72HZdYtpa96g4YN7HNct23hble3GKuxrqk1qAdlV
JSk576ptlJhlzGwSbTE3gyoEMNozwxic3rJfcPSzz0f85OZJRXo6C/5uWwodlH9A
+dMeyDQP6iSDhiprtqzfucTy
-----END PRIVATE KEY-----
"""

timestamp(number::Integer) =
    base64encode([UInt8((UInt64(number) >> (8 * offset)) & 0xff) for offset = 0:7])

version(query_set, identity, ts) =
    Dict("querySet" => query_set, "identity" => identity, "ts" => timestamp(ts))

function transition(
    start_query_set,
    end_query_set,
    start_ts,
    end_ts,
    modifications;
    identity = 0,
)
    return Dict(
        "type" => "Transition",
        "startVersion" => version(start_query_set, identity, start_ts),
        "endVersion" => version(end_query_set, identity, end_ts),
        "modifications" => modifications,
    )
end

updated(id, count; logs = String[]) = Dict(
    "type" => "QueryUpdated",
    "queryId" => id,
    "value" => Dict("count" => count),
    "logLines" => logs,
    "journal" => nothing,
)

failed(id, message; logs = String[]) = Dict(
    "type" => "QueryFailed",
    "queryId" => id,
    "errorMessage" => message,
    "errorData" => Dict("retry" => true),
    "logLines" => logs,
    "journal" => nothing,
)

function wait_until(predicate; timeout = TEST_TIMEOUT, message = "condition")
    timedwait(predicate, timeout; pollint = 0.002) == :ok ||
        error("timed out waiting for $(message)")
end

function take_deadline(channel; timeout = TEST_TIMEOUT, message = "channel value")
    wait_until(() -> isready(channel); timeout, message)
    return take!(channel)
end

function assert_epoch_milliseconds(value)
    @test value isa Integer
    @test 1_000_000_000_000 <= value <= round(Int, time() * 1000) + 60_000
end

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
    error("oversized WebSocket handshake")
end

function server_handshake(socket)
    descriptor = Ref{Cint}(-1)
    ccall(:uv_fileno, Cint, (Ptr{Cvoid}, Ptr{Cint}), socket.handle, descriptor) == 0 ||
        error("fixture could not inspect socket")
    timeout = Ref{NTuple{2,Clong}}((Clong(TEST_TIMEOUT), Clong(0)))
    for option in (20, 21)
        ccall(
            :setsockopt,
            Cint,
            (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
            descriptor[],
            1,
            option,
            timeout,
            sizeof(timeout[]),
        ) == 0 || error("fixture could not set socket deadline")
    end
    headers = read_headers(socket)
    key_match = match(r"(?im)^Sec-WebSocket-Key:\s*([^\r]+)", headers)
    isnothing(key_match) && error("client omitted Sec-WebSocket-Key")
    accept = base64encode(
        sha1(strip(key_match.captures[1]) * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"),
    )
    write(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\n" *
        "Upgrade: websocket\r\n" *
        "Connection: Upgrade\r\n" *
        "Sec-WebSocket-Accept: $(accept)\r\n\r\n",
    )
    flush(socket)
    return nothing
end

function read_client_frame(socket)
    header = read_exact(socket, 2)
    opcode = header[1] & 0x0f
    masked = (header[2] & 0x80) != 0
    masked || error("client frame was not masked")
    length_code = Int(header[2] & 0x7f)
    payload_length = if length_code < 126
        length_code
    elseif length_code == 126
        ext = read_exact(socket, 2)
        Int(UInt16(ext[1]) << 8 | UInt16(ext[2]))
    else
        ext = read_exact(socket, 8)
        value = UInt64(0)
        for byte in ext
            value = value << 8 | UInt64(byte)
        end
        Int(value)
    end
    mask = read_exact(socket, 4)
    payload = read_exact(socket, payload_length)
    for index in eachindex(payload)
        payload[index] = xor(payload[index], mask[(index-1)%4+1])
    end
    return opcode, payload
end

function read_client_json(socket)
    opcode, payload = read_client_frame(socket)
    opcode == 0x01 || error("expected client text frame, got opcode $(opcode)")
    return JSON3.read(String(payload))
end

function frame_bytes(opcode::Integer, payload::Vector{UInt8}; final = true)
    first = UInt8(opcode) | (final ? 0x80 : 0x00)
    length(payload) <= 125 || error("test fixture only uses short fragments")
    return vcat(UInt8[first, UInt8(length(payload))], payload)
end

function long_frame_bytes(opcode::Integer, payload::Vector{UInt8}; final = true)
    first = UInt8(opcode) | (final ? 0x80 : 0x00)
    if length(payload) <= 125
        header = UInt8[first, UInt8(length(payload))]
    elseif length(payload) <= 0xffff
        header =
            UInt8[first, 126, UInt8(length(payload) >> 8), UInt8(length(payload) & 0xff)]
    else
        encoded_length =
            [UInt8((UInt64(length(payload)) >> shift) & 0xff) for shift = 56:-8:0]
        header = vcat(UInt8[first, 127], encoded_length)
    end
    return vcat(header, payload)
end

function send_frame(socket, opcode::Integer, payload::Vector{UInt8}; final = true)
    write(socket, frame_bytes(opcode, payload; final))
    flush(socket)
    return nothing
end

function send_text(socket, value; fragmented = false, ping = false, bytewise = false)
    payload = Vector{UInt8}(JSON3.write(value))
    if bytewise
        wire = UInt8[]
        cursor = 1
        first = true
        while cursor <= length(payload)
            finish = min(cursor + 124, length(payload))
            append!(
                wire,
                frame_bytes(
                    first ? 0x01 : 0x00,
                    payload[cursor:finish];
                    final = finish == length(payload),
                ),
            )
            first = false
            cursor = finish + 1
        end
        cursor = 1
        for width in (1, 2, 5, length(wire))
            cursor > length(wire) && break
            finish = min(cursor + width - 1, length(wire))
            write(socket, wire[cursor:finish])
            flush(socket)
            sleep(0.002)
            cursor = finish + 1
        end
    elseif fragmented
        utf8_boundary = something(findfirst(==(0xc3), payload), length(payload) ÷ 2)
        chunks = Vector{Vector{UInt8}}()
        cursor = 1
        while cursor <= length(payload)
            finish = min(cursor + 124, length(payload))
            if cursor <= utf8_boundary <= finish && utf8_boundary < length(payload)
                finish = utf8_boundary
            end
            push!(chunks, payload[cursor:finish])
            cursor = finish + 1
        end
        for (index, chunk) in enumerate(chunks)
            send_frame(
                socket,
                index == 1 ? 0x01 : 0x00,
                chunk;
                final = index == length(chunks),
            )
            ping &&
                index ==
                findfirst(chunk -> !isempty(chunk) && chunk[end] == 0xc3, chunks) &&
                send_frame(socket, 0x09, UInt8[0x70])
        end
    else
        # Split large JSON into legal WebSocket fragments so the fixture helper
        # itself never relies on a cooperative single-frame receive.
        if length(payload) <= 125
            send_frame(socket, 0x01, payload)
        else
            cursor = 1
            first = true
            while cursor <= length(payload)
                finish = min(cursor + 124, length(payload))
                send_frame(
                    socket,
                    first ? 0x01 : 0x00,
                    payload[cursor:finish];
                    final = finish == length(payload),
                )
                first = false
                cursor = finish + 1
            end
        end
    end
    return nothing
end

function fixture_listener(handler)
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    errors = Channel{Any}(1)
    task = @async try
        handler(listener)
        put!(errors, nothing)
    catch error
        put!(errors, (error, catch_backtrace()))
    finally
        try
            close(listener)
        catch
        end
    end
    return "http://127.0.0.1:$(address[2])", task, errors
end

function finish_fixture(task, errors)
    wait_until(() -> istaskdone(task); message = "fixture completion")
    result = take_deadline(errors; message = "fixture result")
    isnothing(result) || Base.showerror(stderr, result[1], result[2])
    isnothing(result) || throw(result[1])
end

function read_http_request(socket)
    headers = read_headers(socket)
    content_length_match = match(r"(?im)^Content-Length:\s*(\d+)", headers)
    content_length =
        isnothing(content_length_match) ? 0 : parse(Int, content_length_match.captures[1])
    body = content_length == 0 ? UInt8[] : read_exact(socket, content_length)
    request_line = first(split(headers, "\r\n"))
    path = split(request_line)[2]
    return (path = path, headers = headers, body = JSON3.read(String(body)))
end

function send_http_json(socket, value)
    body = JSON3.write(value)
    write(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $(ncodeunits(body))\r\nConnection: close\r\n\r\n",
        body,
    )
    flush(socket)
end

function http_fixture(handler, count::Int)
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    errors = Channel{Any}(1)
    task = @async try
        for index = 1:count
            socket = accept(listener)
            try
                request = read_http_request(socket)
                send_http_json(socket, handler(index, request))
            finally
                close(socket)
            end
        end
        put!(errors, nothing)
    catch error
        put!(errors, (error, catch_backtrace()))
    finally
        close(listener)
    end
    return "http://127.0.0.1:$(address[2])", task, errors
end

@testset "adapter normalizes decoded command args" begin
    command = JSON3.read(
        """{"args":{"room":"stable","nested":{"count":1},"ok":true,"list":[1,null]}}""",
    )
    normalized = command_args(command)
    @test normalized isa Dict{String,Any}
    @test normalized["room"] == "stable"
    @test normalized["ok"] === true
    @test normalized["nested"] isa Dict{String,Any}
    @test normalized["nested"]["count"] == 1
    @test normalized["list"] isa Vector{Any}
    @test normalized["list"] == Any[1, nothing]
    # Public client entry points must collapse every caller shape to the same
    # concrete tree, or the stripped AOT Subscribe path diverges by args type.
    @test Convex.canonicalize_args(Dict("room" => "stable")) isa Dict{String,Any}
    @test Convex.canonicalize_args(normalized) == normalized
end

@testset "canonical values and global delivery budget" begin
    @test Client("https://example.com").deployment_url == "https://example.com"
    @test Client("https://example.com/base/").deployment_url == "https://example.com/base"
    @test Client("http://[::1]:8080").deployment_url == "http://[::1]:8080"
    @test Client("https://example.com"; client_version = "fixture-version").client_version ==
          "fixture-version"
    @test whole_count(0.0, "count") == 0
    @test whole_count(1, "count") == 1
    @test_throws ConvexError whole_count(0.5, "count")
    @test_throws ConvexError whole_count("1", "count")
    @test_throws ConvexError whole_count(Inf, "count")
    @test_throws ConvexError whole_count(NaN, "count")
    @test_throws ConvexError whole_count(1.0e30, "count")
    @test_throws ConvexError whole_count(big(typemax(Int)) + 1, "count")
    @test_throws ConvexError query(
        Client("http://127.0.0.1:1"),
        "demo:state",
        Dict("padding" => repeat("x", Convex.MAX_HTTP_BYTES)),
    )
    closing_client = Client("http://127.0.0.1:1")
    closing_client.closing = true
    closing_error = try
        query(closing_client, "demo:state", Dict())
        nothing
    catch caught
        caught
    end
    @test closing_error isa ConvexError
    @test closing_error.kind == :closed
    @test Convex.timestamp_value("AQAAAAAAAAA=") == UInt64(1)
    @test_throws ConvexError Convex.timestamp_value("AQ==")
    @test_throws ConvexError Convex.timestamp_value("AQAAAAAAAAA")
    @test Convex.wire_int(typemax(UInt32), "queryId") == Int(typemax(UInt32))
    @test_throws ConvexError Convex.wire_int(UInt64(typemax(UInt32)) + 1, "queryId")
    @test_throws ConvexError Convex.wire_int(-1, "queryId")
    @test_throws ConvexError Convex.wire_int(1.0, "queryId")

    budget = Convex.QueueBudget()
    first = Convex.Subscription(nothing, 7, 1, Convex.QueuedUpdate[], budget, false)
    second = Convex.Subscription(nothing, 8, 1, Convex.QueuedUpdate[], budget, false)
    padding = repeat("x", 1024 * 1024 - 256)
    for count = 0:23
        target = iseven(count) ? first : second
        Convex.deliver!(
            target,
            LiveUpdate(Dict("count" => count, "padding" => padding), nothing, String[]),
        )
    end
    @test length(budget.order) <= Convex.MAX_QUEUE_ITEMS
    @test budget.encoded_bytes <= Convex.MAX_QUEUE_BYTES
    retained = sort([entry.update.value["count"] for entry in budget.order])
    @test retained == collect((24-length(retained)):23)
    @test Convex.MAX_QUEUE_ITEMS + MAX_OUTPUT_ITEMS + MAX_TRANSIENT_ITEMS <= 16
    @test Convex.MAX_QUEUE_BYTES + MAX_OUTPUT_BYTES + MAX_TRANSIENT_ENCODED_BYTES <=
          14 * 1024 * 1024
    @test MAX_SERIALIZED_PIPELINE_BYTES <= 20 * 1024 * 1024

    generation_counter = Ref(UInt64(0))
    for _ = 1:1000
        next_adapter_generation!(generation_counter)
    end
    @test generation_counter[] == UInt64(1000)
    generation_counter[] = typemax(UInt64)
    @test_throws ConvexError next_adapter_generation!(generation_counter)

    near_http_result = encode_event(
        Dict(
            "id" => "large-http",
            "type" => "result",
            "value" => Dict("padding" => repeat("h", Convex.MAX_HTTP_BYTES - 4096)),
        ),
    )
    @test length(near_http_result) <= MAX_EVENT_BYTES
    @test length(near_http_result) > Convex.MAX_HTTP_BYTES - 4096
end


@testset "bounded parser read budget accepts pipelined frames" begin
    parser = Convex.FrameParser()
    @test Convex.read_budget(parser) == Convex.NETWORK_READ_CHUNK
    resize!(parser.bytes, Convex.MAX_LIVE_BYTES + 14 - 1000)
    # A near-maximum frame still gets room for its own remaining bytes, and no
    # more, so bytes pipelined behind it stay in the transport.
    @test Convex.read_budget(parser) == 1000
    resize!(parser.bytes, Convex.MAX_LIVE_BYTES + 14)
    overflow = try
        Convex.read_budget(parser)
        nothing
    catch caught
        caught
    end
    @test overflow isa ConvexError
    @test overflow.kind == :protocol
    fragmented = Convex.FrameParser()
    resize!(fragmented.fragmented_payload, Convex.MAX_LIVE_BYTES - 2000)
    resize!(fragmented.bytes, 1500)
    @test Convex.read_budget(fragmented) == 514
end

function fake_manager()
    return Convex.LiveManager(
        "ws://unused",
        "test",
        Channel{Any}(1),
        ReentrantLock(),
        Dict{Int,Any}(),
        Dict{Int,Vector{UInt8}}(),
        Dict{Int,Tuple{Symbol,Vector{UInt8}}}(),
        Set{Int}(),
        Convex.QueueBudget(),
        0,
        1,
        1,
        Convex.zero_version(),
        0,
        "InitialConnect",
        nothing,
        UInt64(0),
        Convex.INITIAL_BACKOFF_SECONDS,
        0.0,
        false,
        true,
        current_task(),
        current_task(),
        current_task(),
    )
end

@testset "frame progress refreshes the partial-frame stall deadline" begin
    manager = fake_manager()
    parser = Convex.FrameParser()
    complete = frame_bytes(0x01, Vector{UInt8}("{}"))
    append!(parser.bytes, complete)
    append!(parser.bytes, UInt8[0x81]) # one deliberate partial header byte
    parser.frame_stall_deadline = time() - 1
    messages, frames = Convex.parse_frames!(parser, manager, nothing; frame_limit = 1)
    @test frames == 1
    @test String(messages[1]) == "{}"
    # A completed frame is progress, so the retained partial frame starts its
    # own deadline instead of inheriting an already expired one.
    @test parser.frame_stall_deadline > time()
    @test parser.bytes == UInt8[0x81]
    armed = parser.frame_stall_deadline
    drained, retried = Convex.parse_frames!(parser, manager, nothing; frame_limit = 1)
    @test isempty(drained)
    @test retried == 0
    # An incomplete frame must never refresh or clear the deadline itself.
    @test parser.frame_stall_deadline == armed
    empty!(parser.bytes)
    append!(parser.bytes, complete)
    Convex.parse_frames!(parser, manager, nothing; frame_limit = 1)
    @test parser.frame_stall_deadline == 0.0
end

@testset "worker retirement finishes subscriptions and rejects commands" begin
    manager = fake_manager()
    subscription =
        Convex.Subscription(manager, 3, 1, Convex.QueuedUpdate[], manager.budget, false)
    pending = Channel{Any}(1)
    manager.subscriptions[3] = (
        path = "demo:state",
        args = Dict(),
        subscription = subscription,
        generation = 1,
        pending_reply = Convex.owner_command(((:subscribe,), pending)),
        request_bytes = 0,
    )
    queued = Channel{Any}(1)
    put!(manager.commands, ((:close,), queued))
    Convex.retire_worker!(manager)
    @test isempty(manager.subscriptions)
    @test subscription.finished
    @test take_deadline(pending; message = "pending subscribe rejection") isa ConvexError
    @test take_deadline(queued; message = "queued command rejection") isa ConvexError
    @test Base.n_avail(manager.commands) == 0
end

@testset "close! completes when the Live worker already stopped" begin
    client = Client("http://127.0.0.1:1")
    manager = fake_manager()
    stopped = @async nothing
    wait(stopped)
    manager.supervisor = stopped
    manager.worker = stopped
    client.live = manager
    started = time()
    close!(client)
    @test time() - started < Convex.CLOSE_TIMEOUT_SECONDS
    @test client.closed
    @test !client.closing
    # Closing twice must stay a bounded no-op rather than throwing.
    close!(client)
    @test client.closed
end

@testset "expired owner commands never execute or leak senders" begin
    full = fake_manager()
    put!(full.commands, :occupied)
    started = time()
    error = try
        Convex.manager_command(full, (:debug_disconnect,); timeout = 0.03)
        nothing
    catch caught
        caught
    end
    @test error isa ConvexError
    @test error.kind == :transport
    @test time() - started < 0.5
    @test Base.n_avail(full.commands) == 1
    @test take!(full.commands) === :occupied

    contended = fake_manager()
    put!(contended.commands, :occupied)
    callers = [
        @async try
            Convex.manager_command(contended, (:debug_disconnect,); timeout = 0.03)
        catch caught
            caught
        end for _ = 1:2
    ]
    for caller in callers
        @test fetch(caller) isa ConvexError
    end
    @test Base.n_avail(contended.commands) == 1
    @test take!(contended.commands) === :occupied

    for command in ((:debug_disconnect,), (:unsubscribe, 7, 1))
        claimed = fake_manager()
        caller = @async try
            Convex.manager_command(claimed, command; timeout = 0.03)
        catch caught
            caught
        end
        envelope = take_deadline(claimed.commands; message = "claimed owner command")
        @test Convex.claim_command!(envelope)
        sleep(0.05)
        @test !istaskdone(caller)
        @test Convex.respond_command!(envelope, nothing)
        @test fetch(caller) === nothing
    end

    stopped = fake_manager()
    stopped_task = @async nothing
    wait(stopped_task)
    stopped.supervisor = stopped_task
    stopped.worker = stopped_task
    for _ = 1:4
        @test_throws ConvexError Convex.manager_command(
            stopped,
            (:debug_disconnect,);
            timeout = 0.02,
        )
    end
    @test Base.n_avail(stopped.commands) == 0

    subscribe_manager = fake_manager()
    @test_throws ConvexError Convex.manager_command(
        subscribe_manager,
        (:subscribe, "demo:state", Dict(), 16);
        timeout = 0.02,
    )
    expired_subscribe = take!(subscribe_manager.commands)
    Convex.handle_disconnected_command!(subscribe_manager, expired_subscribe)
    @test isempty(subscribe_manager.subscriptions)

    unsubscribe_manager = fake_manager()
    subscription = Convex.Subscription(
        unsubscribe_manager,
        7,
        1,
        Convex.QueuedUpdate[],
        unsubscribe_manager.budget,
        false,
    )
    unsubscribe_manager.subscriptions[7] = (
        path = "demo:state",
        args = Dict(),
        subscription = subscription,
        generation = 1,
        pending_reply = nothing,
        request_bytes = 0,
    )
    @test_throws ConvexError Convex.manager_command(
        unsubscribe_manager,
        (:unsubscribe, 7, 1);
        timeout = 0.02,
    )
    Convex.handle_disconnected_command!(
        unsubscribe_manager,
        take!(unsubscribe_manager.commands),
    )
    @test haskey(unsubscribe_manager.subscriptions, 7)

    for command in ((:debug_disconnect,), (:close,))
        manager = fake_manager()
        @test_throws ConvexError Convex.manager_command(manager, command; timeout = 0.02)
        Convex.handle_disconnected_command!(manager, take!(manager.commands))
        @test !manager.closing
    end
end

@testset "retained subscription state count and byte budgets" begin
    manager = fake_manager()
    manager.connected = false
    replies = Channel{Any}[]
    request_bytes = 32
    for index = 1:Convex.MAX_SUBSCRIPTIONS
        reply = Channel{Any}(1)
        push!(replies, reply)
        Convex.handle_disconnected_command!(
            manager,
            (:subscribe, "demo:state", Dict("index" => index), request_bytes, reply),
        )
    end
    @test length(manager.subscriptions) == Convex.MAX_SUBSCRIPTIONS
    @test manager.subscription_bytes == Convex.MAX_SUBSCRIPTIONS * request_bytes
    rejected = Channel{Any}(1)
    Convex.handle_disconnected_command!(
        manager,
        (:subscribe, "demo:state", Dict(), request_bytes, rejected),
    )
    @test take_deadline(rejected) isa ConvexError
    first_id = minimum(keys(manager.subscriptions))
    Convex.remove_subscription!(manager, first_id, 1)
    @test manager.subscription_bytes == (Convex.MAX_SUBSCRIPTIONS - 1) * request_bytes
    @test length(manager.subscriptions) == Convex.MAX_SUBSCRIPTIONS - 1
    for (id, state) in collect(manager.subscriptions)
        Convex.remove_subscription!(manager, id, state.generation)
    end
    @test manager.subscription_bytes == 0
end

@testset "transactional transitions, log validation, and recovery" begin
    manager = fake_manager()
    subscription =
        Convex.Subscription(manager, 0, 1, Convex.QueuedUpdate[], manager.budget, false)
    manager.subscriptions[0] = (
        path = "demo:state",
        args = Dict(),
        subscription = subscription,
        generation = 1,
        pending_reply = nothing,
        request_bytes = 0,
    )

    initial = transition(0, 1, 0, 1, [updated(0, 0; logs = ["initial"])])
    Convex.apply_transition!(manager, initial)
    @test next_update(subscription).logs == ["initial"]
    committed_version = manager.remote_version
    committed_timestamp = manager.max_observed_timestamp

    malformed = transition(1, 1, 1, 2, [updated(0, 1), updated(0, 2; logs = Any["ok", 7])])
    @test_throws ConvexError Convex.apply_transition!(manager, malformed)
    @test manager.remote_version == committed_version
    @test manager.max_observed_timestamp == committed_timestamp
    @test isempty(subscription.queue)

    scalar_version = transition(1, 1, 1, 2, [updated(0, 1)])
    scalar_version["startVersion"] = 7
    scalar_modification = transition(1, 1, 1, 2, Any[7])
    for invalid in (scalar_version, scalar_modification)
        error = try
            Convex.apply_transition!(manager, invalid)
            nothing
        catch caught
            caught
        end
        @test error isa ConvexError
        @test error.kind == :protocol
        @test manager.remote_version == committed_version
        @test manager.max_observed_timestamp == committed_timestamp
    end

    # Multiple entries for one query coalesce. The last QueryFailed is the only
    # observable update, then the same subscription recovers on QueryUpdated.
    Convex.apply_transition!(
        manager,
        transition(1, 1, 1, 2, [updated(0, 1), failed(0, "temporary")]),
    )
    failure = next_update(subscription)
    @test failure.error.kind == :function_error
    @test failure.error.data["retry"] == true
    Convex.apply_transition!(manager, transition(1, 1, 2, 3, [updated(0, 2)]))
    @test next_update(subscription).value["count"] == 2

    # A newer ModifyQuerySet may already be sent while the server still emits
    # a legal transition at the previous remote query-set version.
    manager.query_set_version = 2
    Convex.apply_transition!(manager, transition(1, 1, 3, 4, [updated(0, 3)]))
    @test next_update(subscription).value["count"] == 3
    Convex.apply_transition!(
        manager,
        transition(1, 1, 4, 5, [updated(0, 3; logs = ["same value, new event"])]),
    )
    @test next_update(subscription).logs == ["same value, new event"]
    push!(manager.pending_hydration, 0)
    Convex.apply_transition!(
        manager,
        transition(1, 1, 5, 6, [updated(0, 3; logs = ["reconnect hydration"])]),
    )
    @test next_update(subscription).logs == ["reconnect hydration"]
    push!(manager.pending_hydration, 0)
    Convex.apply_transition!(
        manager,
        transition(1, 1, 6, 7, [updated(0, 3; logs = ["reconnect hydration"])]),
    )
    @test isempty(subscription.queue)
    unknown = [updated(10_000 + index, index) for index = 1:1000]
    Convex.apply_transition!(manager, transition(1, 1, 7, 8, unknown))
    @test collect(keys(manager.remote_values)) == [0]
    Convex.apply_transition!(
        manager,
        transition(1, 2, 8, 9, [Dict("type" => "QueryRemoved", "queryId" => 0)]),
    )
    @test manager.remote_version.query_set == 2
end

@testset "real HTTP transport and serialized adapter event shapes" begin
    requests = Any[]
    url, fixture, fixture_errors = http_fixture(7) do index, request
        push!(requests, request)
        if index == 4
            7
        elseif index == 7
            Dict("status" => "unexpected", "logLines" => String[])
        elseif request.path == "/api/query"
            Dict(
                "status" => "success",
                "value" => Dict("count" => 0.0),
                "logLines" => ["query log"],
            )
        elseif request.path == "/api/mutation"
            Dict(
                "status" => "error",
                "errorMessage" => "expected failure",
                "errorData" => Dict("code" => "fixture"),
                "logLines" => ["mutation log"],
            )
        else
            Dict(
                "status" => "success",
                "value" => Dict("acted" => true),
                "logLines" => String[],
            )
        end
    end

    client = Client(url; auth_token = "fixture-token", client_version = "julia-fixture")
    result = query(client, "demo:state", Dict("room" => "http"))
    @test whole_count(result.value["count"], "count") == 0
    @test result.logs == ["query log"]
    mutation_error = try
        mutation(client, "demo:increment", Dict("room" => "http"))
        nothing
    catch error
        error
    end
    @test mutation_error isa ConvexError
    @test mutation_error.kind == :function_error
    @test mutation_error.data["code"] == "fixture"
    @test mutation_error.logs == ["mutation log"]
    @test action(client, "demo:action", Dict()).value["acted"] == true
    protocol_error = try
        query(client, "demo:state", Dict("malformed" => true))
        nothing
    catch error
        error
    end
    @test protocol_error isa ConvexError
    @test protocol_error.kind == :protocol
    close!(client)
    @test all(
        occursin("Authorization: Bearer fixture-token", request.headers) for
        request in requests
    )
    @test all(
        occursin("Convex-Client: julia-fixture", request.headers) for request in requests
    )

    old_url = get(ENV, "CONVEX_URL", nothing)
    ENV["CONVEX_URL"] = url
    adapter_input = IOBuffer(
        "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n" *
        "{\"id\":\"query\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n" *
        "{\"id\":\"mutation\",\"op\":\"mutation\",\"path\":\"demo:increment\",\"args\":{}}\n" *
        "{\"id\":\"protocol\",\"op\":\"action\",\"path\":\"demo:action\",\"args\":{}}\n" *
        "{\"id\":\"close\",\"op\":\"close\"}\n",
    )
    adapter_output = IOBuffer()
    try
        run_adapter(adapter_input, adapter_output)
    finally
        isnothing(old_url) ? delete!(ENV, "CONVEX_URL") : (ENV["CONVEX_URL"] = old_url)
    end
    events = [
        JSON3.read(line) for
        line in split(String(take!(adapter_output)), '\n') if !isempty(line)
    ]
    @test [event[:type] for event in events] == ["ready", "result", "error", "error", "closed"]
    @test events[1][:language] == "julia"
    # Provenance and runtime are evidence. Both must describe the toolchain
    # that actually built this adapter rather than a pinned literal.
    @test events[1][:implementation] == "native-julia-" * string(VERSION)
    @test events[1][:runtime] == "julia-" * string(VERSION)
    @test events[2][:logs] == ["query log"]
    @test events[3][:error][:name] == "FunctionError"
    @test events[3][:error][:data][:code] == "fixture"
    @test events[3][:logs] == ["mutation log"]
    @test events[4][:error][:name] == "ProtocolError"
    finish_fixture(fixture, fixture_errors)

    unreachable = listen(ip"127.0.0.1", 0)
    unreachable_port = getsockname(unreachable)[2]
    close(unreachable)
    transport_error = try
        query(Client("http://127.0.0.1:$(unreachable_port)"), "demo:state", Dict())
        nothing
    catch error
        error
    end
    @test transport_error isa ConvexError
    @test transport_error.kind == :transport
end

@testset "decoded values are plain Julia trees, not JSON3 views" begin
    url, fixture, fixture_errors = http_fixture(2) do index, request
        index == 1 && return Dict(
            "status" => "success",
            "value" => Dict(
                "unicode" => "Hello, 世界 👋",
                "nested" => Dict(
                    "booleans" => [true, false],
                    "number" => 42.5,
                    "nil" => nothing,
                ),
                "ids" => ["a", "b"],
            ),
            "logLines" => String[],
        )
        return Dict(
            "status" => "error",
            "errorMessage" => "expected failure",
            "errorData" => Dict("code" => "FIXTURE", "flags" => [true, false]),
            "logLines" => String[],
        )
    end
    client = Client(url)
    value = query(client, "demo:echo", Dict()).value
    failure = try
        query(client, "demo:fail", Dict())
        nothing
    catch caught
        caught
    end
    close!(client)

    # A JSON3 view would pin the whole response it arrived in, and a stripped
    # AOT image would need a serializer specialization for every concrete view
    # type a deployment happens to return.
    @test value isa Dict{String,Any}
    @test value["nested"] isa Dict{String,Any}
    @test value["nested"]["booleans"] isa Vector{Any}
    @test value["nested"]["booleans"] == Any[true, false]
    @test value["nested"]["booleans"][1] === true
    @test value["nested"]["number"] == 42.5
    @test value["nested"]["nil"] === nothing
    @test value["ids"] isa Vector{Any}
    @test value["unicode"] == "Hello, 世界 👋"
    @test failure isa ConvexError
    @test failure.data isa Dict{String,Any}
    @test failure.data["flags"] isa Vector{Any}
    finish_fixture(fixture, fixture_errors)

    manager = fake_manager()
    subscription =
        Convex.Subscription(manager, 0, 1, Convex.QueuedUpdate[], manager.budget, false)
    manager.subscriptions[0] = (
        path = "demo:state",
        args = Dict(),
        subscription = subscription,
        generation = 1,
        pending_reply = nothing,
        request_bytes = 0,
    )
    Convex.apply_transition!(
        manager,
        transition(
            0,
            1,
            0,
            1,
            [
                Dict(
                    "type" => "QueryUpdated",
                    "queryId" => 0,
                    "value" => Dict("flags" => [true, false]),
                    "logLines" => String[],
                ),
            ],
        ),
    )
    live_value = next_update(subscription).value
    @test live_value isa Dict{String,Any}
    @test live_value["flags"] isa Vector{Any}
end

@testset "adapter reports missing command fields as protocol errors" begin
    input = IOBuffer(
        "{\"id\":\"no-path\",\"op\":\"query\",\"args\":{}}\n" *
        "{\"id\":\"empty-path\",\"op\":\"subscribe\",\"subscriptionId\":\"s\",\"path\":\"\"}\n" *
        "{\"id\":\"close\",\"op\":\"close\"}\n",
    )
    output = IOBuffer()
    run_adapter(input, output)
    events =
        [JSON3.read(line) for line in split(String(take!(output)), '\n') if !isempty(line)]
    @test [event[:type] for event in events] == ["error", "error", "closed"]
    # A command the controller malformed is a protocol fault, not an untyped
    # Julia ArgumentError leaking into the NDJSON stream.
    @test [event[:error][:name] for event in events[1:2]] == ["ProtocolError", "ProtocolError"]
    @test [event[:id] for event in events] == ["no-path", "empty-path", "close"]
end

@testset "HTTP status and declared/chunked response limits" begin
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    errors = Channel{Any}(1)
    fixture = @async try
        for mode in (:status, :declared, :chunked)
            socket = accept(listener)
            try
                read_http_request(socket)
                if mode == :status
                    body = "{\"status\":\"success\",\"value\":{}}"
                    write(
                        socket,
                        "HTTP/1.1 503 Service Unavailable\r\nContent-Length: $(ncodeunits(body))\r\nConnection: close\r\n\r\n",
                        body,
                    )
                elseif mode == :declared
                    write(
                        socket,
                        "HTTP/1.1 200 OK\r\nContent-Length: $(Convex.MAX_HTTP_BYTES + 1)\r\nConnection: close\r\n\r\n",
                    )
                else
                    write(
                        socket,
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                    )
                    chunk = fill(UInt8('x'), 64 * 1024)
                    try
                        for _ = 1:40
                            write(
                                socket,
                                string(length(chunk), base = 16),
                                "\r\n",
                                chunk,
                                "\r\n",
                            )
                            flush(socket)
                        end
                        write(socket, "0\r\n\r\n")
                    catch error
                        error isa Base.IOError || rethrow()
                    end
                end
                try
                    flush(socket)
                catch error
                    mode == :chunked && error isa Base.IOError || rethrow()
                end
            finally
                close(socket)
            end
        end
        put!(errors, nothing)
    catch error
        put!(errors, (error, catch_backtrace()))
    finally
        close(listener)
    end
    url = "http://127.0.0.1:$(address[2])"
    for expected in (:status, :declared, :chunked)
        error = try
            query(Client(url), "demo:state", Dict("case" => String(expected)))
            nothing
        catch caught
            caught
        end
        @test error isa ConvexError
        @test error.kind == :transport
        expected == :status && @test error.data["status"] == 503
    end
    finish_fixture(fixture, errors)
end

@testset "real WebSocket Add, fragmented UTF-8/control, QueryFailed, Remove" begin
    remove_seen = Channel{Bool}(1)
    url, fixture, fixture_errors = fixture_listener() do listener
        socket = accept(listener)
        try
            server_handshake(socket)
            connect = read_client_json(socket)
            add = read_client_json(socket)
            @test connect["connectionCount"] == 0
            @test connect["lastCloseReason"] == "InitialConnect"
            assert_epoch_milliseconds(connect["clientTs"])
            @test !haskey(connect, :maxObservedTimestamp)
            @test add["modifications"][1]["type"] == "Add"
            @test add["modifications"][1]["udfPath"] == "demo:state"
            id = Int(add["modifications"][1]["queryId"])
            send_text(
                socket,
                transition(0, 1, 0, 1, [updated(id, 0; logs = ["héllo"])]);
                fragmented = true,
                ping = true,
            )
            pong_opcode, pong_payload = read_client_frame(socket)
            @test pong_opcode == 0x0a
            @test pong_payload == UInt8[0x70]
            send_text(
                socket,
                transition(1, 1, 1, 2, [failed(id, "temporary")]);
                bytewise = true,
            )
            send_text(socket, transition(1, 1, 2, 3, [updated(id, 1)]))
            send_text(
                socket,
                transition(1, 1, 3, 4, [updated(id, 1; logs = ["same value later"])]),
            )
            remove = read_client_json(socket)
            put!(remove_seen, remove["modifications"][1]["type"] == "Remove")
        finally
            close(socket)
        end
    end

    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "fixture"))
    @test client.live.owner_task !== nothing
    @test client.live.worker === client.live.owner_task
    @test client.live.owner_task === client.live.supervisor
    query_set_before = client.live.query_set_version
    escaped = Channel{Any}(1)
    attempt = @async put!(
        escaped,
        try
            Convex.modify_query_set!(
                client.live,
                nothing,
                [Dict("type" => "Remove", "queryId" => 999)],
            )
            nothing
        catch error
            error
        end,
    )
    owner_error = take_deadline(escaped; message = "wrong-task owner guard")
    @test owner_error isa ConvexError
    @test owner_error.kind == :protocol
    @test client.live.query_set_version == query_set_before
    wait(attempt)
    initial = next_update(subscription)
    @test initial.error === nothing
    @test initial.value["count"] == 0
    @test initial.logs == ["héllo"]
    failure = next_update(subscription)
    @test failure.error.kind == :function_error
    recovered = next_update(subscription)
    @test recovered.error === nothing
    @test recovered.value["count"] == 1
    @test next_update(subscription).logs == ["same value later"]
    unsubscribe!(subscription)
    @test take_deadline(remove_seen; message = "Remove frame")
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "connected peer EOF is not reported as a handshake failure" begin
    url, fixture, fixture_errors = fixture_listener() do listener
        socket = accept(listener)
        server_handshake(socket)
        read_client_json(socket)
        read_client_json(socket)
        close(socket)
    end
    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "connected-eof"))
    failure = next_update(subscription; timeout = 4)
    @test failure.error.kind == :transport
    # The same bounded read serves the handshake and the connected owner. A
    # session that ends after Add must not be reported, or replayed to the
    # server as lastCloseReason, as a handshake failure.
    @test !occursin("handshake", failure.error.message)
    @test !occursin("handshake", client.live.last_close_reason)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "last Remove acknowledgement retires the idle WebSocket" begin
    remove_seen = Channel{Nothing}(1)
    peer_retired = Channel{Nothing}(1)
    url, fixture, fixture_errors = fixture_listener() do listener
        socket = accept(listener)
        try
            server_handshake(socket)
            read_client_json(socket)
            add = read_client_json(socket)
            id = Int(add["modifications"][1]["queryId"])
            send_text(socket, transition(0, 1, 0, 1, [updated(id, 0)]))
            remove = read_client_json(socket)
            put!(remove_seen, nothing)
            @test length(remove["modifications"]) == 1
            @test remove["modifications"][1]["type"] == "Remove"
            @test remove["modifications"][1]["queryId"] == id
            try
                while true
                    read(socket, UInt8)
                end
            catch
            end
            put!(peer_retired, nothing)
        finally
            close(socket)
        end
    end
    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "idle-retire"))
    @test next_update(subscription).value["count"] == 0
    unsubscribe!(subscription)
    take_deadline(remove_seen; message = "last Remove wire barrier")
    take_deadline(peer_retired; timeout = 1, message = "idle WebSocket retirement")
    wait_until(
        () -> !client.live.connected;
        timeout = 1,
        message = "idle owner disconnected",
    )
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "native WSS partial TLS record and reconnect recovery" begin
    @test string(Convex.HTTP.SOCKET_TYPE_TLS[]) == "OpenSSL.SSLStream"
    fixture_dir = mktempdir()
    cert_path = joinpath(fixture_dir, "cert.pem")
    key_path = joinpath(fixture_dir, "key.pem")
    write(cert_path, TEST_TLS_CERT)
    write(key_path, TEST_TLS_KEY)

    connection_lock = ReentrantLock()
    connection_number = Ref(0)
    stall_tls_record = Channel{Nothing}(1)
    remove_observed = Channel{Nothing}(1)
    server_errors = Channel{Any}(2)
    tls_server = Convex.HTTP.WebSockets.listen!(
        ip"127.0.0.1",
        0;
        sslconfig = Convex.HTTP.SSLConfig(cert_path, key_path),
        suppress_close_error = true,
    ) do websocket
        index = lock(connection_lock) do
            connection_number[] += 1
            connection_number[]
        end
        phase = "Connect"
        try
            JSON3.read(String(Convex.HTTP.WebSockets.receive(websocket)))
            phase = "Add"
            add = JSON3.read(String(Convex.HTTP.WebSockets.receive(websocket)))
            id = Int(add["modifications"][1]["queryId"])
            if index == 1
                put!(stall_tls_record, nothing)
                Convex.HTTP.WebSockets.send(
                    websocket,
                    JSON3.write(transition(0, 1, 0, 1, [updated(id, 0)])),
                )
                sleep(3)
            else
                phase = "valid transition"
                Convex.HTTP.WebSockets.send(
                    websocket,
                    JSON3.write(transition(0, 1, 0, 1, [updated(id, 1)])),
                )
                phase = "Remove"
                remove = JSON3.read(String(Convex.HTTP.WebSockets.receive(websocket)))
                @test remove["modifications"][1]["type"] == "Remove"
                put!(remove_observed, nothing)
            end
            put!(server_errors, nothing)
        catch error
            # The first connection is deliberately truncated by the proxy and
            # may end with a normal transport exception.
            index == 1 ? put!(server_errors, nothing) :
            put!(server_errors, (connection = index, phase = phase, error = error))
        end
    end

    function relay_raw(source, destination)
        try
            while isopen(source) && isopen(destination)
                if bytesavailable(source) > 0
                    bytes = read(source, min(bytesavailable(source), 64 * 1024))
                    write(destination, bytes)
                    flush(destination)
                    continue
                end
                source.status == Base.StatusEOF && break
                descriptor = Convex.socket_descriptor(source)
                if Convex.poll_read_ready(descriptor)
                    count = max(1, min(bytesavailable(source), 64 * 1024))
                    bytes = read(source, count)
                    isempty(bytes) && break
                    write(destination, bytes)
                    flush(destination)
                else
                    sleep(0.001)
                end
            end
        catch
        finally
            try
                close(destination)
            catch
            end
        end
        return nothing
    end

    function retire_raw(socket)
        try
            descriptor = Convex.socket_descriptor(socket)
            ccall(:shutdown, Cint, (Cint, Cint), descriptor, 2)
        catch
        end
        try
            close(socket)
        catch
        end
        return nothing
    end

    proxy_listener = listen(ip"127.0.0.1", 0)
    proxy_port = getsockname(proxy_listener)[2]
    partial_forwarded = Channel{Nothing}(1)
    partial_peer_retired = Channel{Float64}(1)
    proxy_errors = Channel{Any}(1)
    proxy = @async try
        for index = 1:2
            downstream = accept(proxy_listener)
            tls_port = getsockname(tls_server.listener.server)[2]
            upstream = connect(ip"127.0.0.1", tls_port)
            if index == 1
                client_to_server = @async relay_raw(downstream, upstream)
                while !isready(stall_tls_record)
                    if bytesavailable(upstream) > 0 ||
                       Convex.poll_read_ready(Convex.socket_descriptor(upstream))
                        count = max(1, min(bytesavailable(upstream), 64 * 1024))
                        write(downstream, read(upstream, count))
                        flush(downstream)
                    else
                        sleep(0.001)
                    end
                end
                take!(stall_tls_record)
                wait_until(
                    () ->
                        bytesavailable(upstream) > 0 ||
                        Convex.poll_read_ready(Convex.socket_descriptor(upstream));
                    message = "encrypted transition record",
                )
                encrypted =
                    read(upstream, max(1, min(bytesavailable(upstream), 64 * 1024)))
                # Five bytes are exactly a TLS record header. The encrypted
                # payload is withheld so the production OpenSSL read path must
                # abandon or preserve this connection within its deadline.
                write(downstream, encrypted[1:min(5, length(encrypted))])
                flush(downstream)
                put!(partial_forwarded, nothing)
                partial_started = time()
                # Do not cooperatively close this side. The production client
                # must abandon the withheld TLS record and close downstream
                # while the proxy itself remains willing to keep it open.
                timedwait(() -> istaskdone(client_to_server), 5; pollint = 0.002) == :ok || error("client did not retire stalled partial TLS record")
                put!(partial_peer_retired, time() - partial_started)
                close(downstream)
                close(upstream)
                wait(client_to_server)
            else
                client_to_server = @async relay_raw(downstream, upstream)
                server_to_client = @async relay_raw(upstream, downstream)
                take_deadline(remove_observed; message = "TLS Remove")
                retire_raw(downstream)
                retire_raw(upstream)
                wait(client_to_server)
                wait(server_to_client)
            end
        end
        put!(proxy_errors, nothing)
    catch error
        put!(proxy_errors, error)
    finally
        close(proxy_listener)
    end

    old_roots = get(ENV, "JULIA_SSL_CA_ROOTS_PATH", nothing)
    old_no_verify = get(ENV, "JULIA_SSL_NO_VERIFY_HOSTS", nothing)
    ENV["JULIA_SSL_CA_ROOTS_PATH"] = cert_path
    ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = "127.0.0.1"
    client = Client("https://127.0.0.1:$(proxy_port)")
    try
        subscription = subscribe(client, "demo:state", Dict("room" => "native-wss"))
        take_deadline(partial_forwarded; message = "partial TLS record forwarded")
        started = time()
        @test next_update(subscription; timeout = 4).error.kind == :transport
        @test time() - started < 3.5
        @test take_deadline(
            partial_peer_retired;
            timeout = 1,
            message = "client-owned partial TLS retirement",
        ) < 3.5
        recovered = next_update(subscription; timeout = 4)
        @test recovered.error === nothing
        @test recovered.value["count"] == 1
        @test lock(connection_lock) do
            connection_number[] == 2
        end
        @test client.live.connection_count == 1
        close_started = time()
        unsubscribe!(subscription)
        close!(client)
        @test time() - close_started < 1.5
    finally
        try
            close!(client)
        catch
        end
        isnothing(old_roots) ? delete!(ENV, "JULIA_SSL_CA_ROOTS_PATH") :
        (ENV["JULIA_SSL_CA_ROOTS_PATH"] = old_roots)
        isnothing(old_no_verify) ? delete!(ENV, "JULIA_SSL_NO_VERIFY_HOSTS") :
        (ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = old_no_verify)
        try
            Convex.HTTP.forceclose(tls_server)
        catch
        end
    end
    wait(proxy)
    @test take_deadline(proxy_errors; message = "TLS proxy completion") === nothing
    for _ = 1:2
        @test take_deadline(server_errors; message = "TLS server completion") === nothing
    end
end

@testset "real old-query-set Add and Remove acknowledgement barriers" begin
    url, fixture, fixture_errors = fixture_listener() do listener
        socket = accept(listener)
        try
            server_handshake(socket)
            read_client_json(socket)
            first_add = read_client_json(socket)
            first_id = Int(first_add["modifications"][1]["queryId"])
            send_text(socket, transition(0, 1, 0, 1, [updated(first_id, 0)]))

            second_add = read_client_json(socket)
            @test second_add["baseVersion"] == 1
            @test second_add["newVersion"] == 2
            second_id = Int(second_add["modifications"][1]["queryId"])
            # This legal transition was already in flight for the older remote
            # query set when the second Add crossed the write barrier.
            send_text(socket, transition(1, 1, 1, 2, [updated(first_id, 1)]))
            send_text(socket, transition(1, 2, 2, 3, [updated(second_id, 0)]))

            remove = read_client_json(socket)
            @test remove["baseVersion"] == 2
            @test remove["newVersion"] == 3
            @test remove["modifications"][1]["queryId"] == first_id
            send_text(
                socket,
                transition(
                    2,
                    3,
                    3,
                    4,
                    [
                        Dict("type" => "QueryRemoved", "queryId" => first_id),
                        updated(second_id, 1),
                    ],
                ),
            )
            try
                while true
                    read(socket, UInt8)
                end
            catch
            end
        finally
            close(socket)
        end
    end

    client = Client(url)
    first = subscribe(client, "demo:state", Dict("room" => "first"))
    @test next_update(first).value["count"] == 0
    second = subscribe(client, "demo:state", Dict("room" => "second"))
    @test next_update(first).value["count"] == 1
    @test next_update(second).value["count"] == 0
    unsubscribe!(first)
    @test_throws ConvexError next_update(first; timeout = 0.05)
    @test next_update(second).value["count"] == 1
    unsubscribe!(second)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "buffered control burst and near-maximum inbound frame" begin
    template = Dict(
        "type" => "Transition",
        "startVersion" => version(0, 0, 0),
        "endVersion" => version(1, 0, 1),
        "modifications" => [
            Dict(
                "type" => "QueryUpdated",
                "queryId" => 0,
                "value" => Dict("padding" => ""),
                "logLines" => String[],
            ),
        ],
    )
    padding = repeat("v", Convex.MAX_LIVE_BYTES - ncodeunits(JSON3.write(template)))
    url, fixture, fixture_errors = fixture_listener() do listener
        socket = accept(listener)
        try
            server_handshake(socket)
            read_client_json(socket)
            add = read_client_json(socket)
            id = Int(add["modifications"][1]["queryId"])
            for _ = 1:40_000
                write(socket, frame_bytes(0x0a, UInt8[]))
            end
            payload = Vector{UInt8}(
                JSON3.write(
                    Dict(
                        "type" => "Transition",
                        "startVersion" => version(0, 0, 0),
                        "endVersion" => version(1, 0, 1),
                        "modifications" => [
                            Dict(
                                "type" => "QueryUpdated",
                                "queryId" => id,
                                "value" => Dict("padding" => padding),
                                "logLines" => String[],
                            ),
                        ],
                    ),
                ),
            )
            @test length(payload) == Convex.MAX_LIVE_BYTES
            write(socket, long_frame_bytes(0x01, payload))
            # Pipeline a control frame directly behind the near-maximum text
            # frame. A bounded reader must leave those bytes in the transport
            # rather than treating a conforming peer as an oversized frame.
            write(socket, frame_bytes(0x0a, UInt8[]))
            flush(socket)
            try
                while true
                    read(socket, UInt8)
                end
            catch
            end
        finally
            close(socket)
        end
    end
    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "large"))
    update = next_update(subscription; timeout = 15)
    @test update.error === nothing
    @test ncodeunits(String(update.value["padding"])) == ncodeunits(padding)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "five reconnect barriers, metadata, Add replay, silent hydration" begin
    connected = Channel{Int}(6)
    release_external = Channel{Nothing}(1)
    records = Any[]
    url, fixture, fixture_errors = fixture_listener() do listener
        for connection = 0:5
            socket = accept(listener)
            try
                server_handshake(socket)
                connect = read_client_json(socket)
                add = read_client_json(socket)
                push!(records, (connect = connect, add = add))
                id = Int(add["modifications"][1]["queryId"])
                send_text(socket, transition(0, 1, 0, connection + 1, [updated(id, 0)]))
                put!(connected, connection)
                if connection == 5
                    take_deadline(release_external; message = "external update release")
                    send_text(socket, transition(1, 1, 6, 7, [updated(id, 1)]))
                end
                try
                    while true
                        read(socket, UInt8)
                    end
                catch
                end
            finally
                close(socket)
            end
        end
    end

    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "reconnect"))
    @test next_update(subscription).value["count"] == 0
    @test take_deadline(connected; message = "initial connection") == 0
    sole_owner = client.live.owner_task
    @test sole_owner === client.live.supervisor
    for connection = 1:5
        debug_disconnect_for_adapter(client)
        @test take_deadline(connected; message = "reconnect $(connection)") == connection
        # The supervisor itself owns every successive socket. There is no
        # detached reader or callback task from an old connection to outlive
        # the debug-disconnect acknowledgement.
        @test client.live.owner_task === sole_owner
        @test client.live.worker === sole_owner
        @test client.live.supervisor === sole_owner
        @test !istaskdone(sole_owner)
        wait_until(
            () -> client.live.max_observed_timestamp_value >= UInt64(connection + 1);
            message = "reconnect hydration",
        )
        @test client.live.next_backoff == Convex.INITIAL_BACKOFF_SECONDS
    end
    put!(release_external, nothing)
    @test next_update(subscription).value["count"] == 1
    @test_throws ConvexError next_update(subscription; timeout = 0.05)
    @test length(records) == 6
    for (index, record) in enumerate(records)
        assert_epoch_milliseconds(record.connect["clientTs"])
        @test record.connect["connectionCount"] == index - 1
        @test record.add["modifications"][1]["type"] == "Add"
        if index == 1
            @test !haskey(record.connect, :maxObservedTimestamp)
        else
            @test record.connect["lastCloseReason"] == "DebugDisconnect"
            @test record.connect["maxObservedTimestamp"] == timestamp(index - 1)
        end
    end
    @test issorted([Int(record.connect["clientTs"]) for record in records])
    unsubscribe!(subscription)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "reconnect hydration preserves changed logs and suppresses identical logs" begin
    connected = Channel{Int}(3)
    release_update = Channel{Nothing}(1)
    url, fixture, fixture_errors = fixture_listener() do listener
        for connection = 0:2
            socket = accept(listener)
            try
                server_handshake(socket)
                read_client_json(socket)
                add = read_client_json(socket)
                id = Int(add["modifications"][1]["queryId"])
                logs = connection == 0 ? ["base"] : ["changed on reconnect"]
                send_text(
                    socket,
                    transition(0, 1, 0, connection + 1, [updated(id, 0; logs)]),
                )
                put!(connected, connection)
                if connection == 2
                    take_deadline(release_update; message = "logged hydration release")
                    send_text(
                        socket,
                        transition(1, 1, 3, 4, [updated(id, 1; logs = ["external"])]),
                    )
                end
                try
                    while true
                        read(socket, UInt8)
                    end
                catch
                end
            finally
                close(socket)
            end
        end
    end
    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "hydration-logs"))
    @test next_update(subscription).logs == ["base"]
    @test take_deadline(connected) == 0
    debug_disconnect_for_adapter(client)
    @test take_deadline(connected) == 1
    @test next_update(subscription).logs == ["changed on reconnect"]
    debug_disconnect_for_adapter(client)
    @test take_deadline(connected) == 2
    wait_until(
        () -> client.live.max_observed_timestamp_value >= UInt64(3);
        message = "identical logged hydration",
    )
    @test_throws ConvexError next_update(subscription; timeout = 0.05)
    put!(release_update, nothing)
    update = next_update(subscription)
    @test update.value["count"] == 1
    @test update.logs == ["external"]
    unsubscribe!(subscription)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "real transport backoff escalation and healthy reset" begin
    accepted_at = Float64[]
    final_connect = Channel{Any}(1)
    release_final = Channel{Nothing}(1)
    url, fixture, fixture_errors = fixture_listener() do listener
        for connection = 1:4
            socket = accept(listener)
            push!(accepted_at, time())
            if connection in (2, 3)
                read_headers(socket)
                write(
                    socket,
                    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                flush(socket)
                close(socket)
                continue
            end
            try
                server_handshake(socket)
                connect = read_client_json(socket)
                add = read_client_json(socket)
                id = Int(add["modifications"][1]["queryId"])
                send_text(socket, transition(0, 1, 0, connection, [updated(id, 0)]))
                if connection == 1
                    sleep(0.02)
                else
                    put!(final_connect, connect)
                    take_deadline(release_final; message = "release healthy backoff peer")
                end
            finally
                close(socket)
            end
        end
    end

    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "backoff"))
    @test next_update(subscription).value["count"] == 0
    errors = 0
    while true
        update = next_update(subscription; timeout = 5)
        if isnothing(update.error)
            @test update.value["count"] == 0
            break
        end
        errors += 1
        @test update.error.kind == :transport
    end
    connect = take_deadline(final_connect; message = "post-backoff healthy connection")
    @test errors >= 3
    @test accepted_at[3] - accepted_at[2] >= 0.15
    @test accepted_at[4] - accepted_at[3] >= 0.30
    @test client.live.next_backoff == Convex.INITIAL_BACKOFF_SECONDS
    assert_epoch_milliseconds(connect["clientTs"])
    put!(release_final, nothing)
    finish_fixture(fixture, fixture_errors)
    close!(client)
end

@testset "bounded close with stalled partial and continuous peers" begin
    for mode in (:partial, :continuous)
        stop = Ref(false)
        url, fixture, fixture_errors = fixture_listener() do listener
            socket = accept(listener)
            try
                server_handshake(socket)
                read_client_json(socket)
                read_client_json(socket)
                if mode == :partial
                    write(socket, UInt8[0x81])
                    flush(socket)
                    while !stop[]
                        sleep(0.002)
                    end
                else
                    while !stop[]
                        send_frame(socket, 0x0a, UInt8[])
                        sleep(0.0005)
                    end
                end
            catch
            finally
                close(socket)
            end
        end
        client = Client(url)
        subscription = subscribe(client, "demo:state", Dict("room" => String(mode)))
        wait_until(() -> client.live.connected; message = "fixture WebSocket connection")
        started = time()
        close!(client)
        @test time() - started < Convex.CLOSE_TIMEOUT_SECONDS
        stop[] = true
        finish_fixture(fixture, fixture_errors)
        @test_throws ConvexError next_update(subscription; timeout = 0.05)
    end
end

@testset "stalled partial WebSocket frame retires and recovers" begin
    partial_sent = Channel{Nothing}(1)
    peer_retired = Channel{Float64}(1)
    records = Any[]
    url, fixture, fixture_errors = fixture_listener() do listener
        for connection = 1:2
            socket = accept(listener)
            try
                server_handshake(socket)
                connect = read_client_json(socket)
                push!(records, connect)
                add = read_client_json(socket)
                id = Int(add["modifications"][1]["queryId"])
                if connection == 1
                    write(socket, UInt8[0x81])
                    flush(socket)
                    put!(partial_sent, nothing)
                    started = time()
                    try
                        while true
                            read(socket, UInt8)
                        end
                    catch
                    end
                    put!(peer_retired, time() - started)
                else
                    send_text(socket, transition(0, 1, 0, 1, [updated(id, 1)]))
                    remove = read_client_json(socket)
                    @test remove["modifications"][1]["type"] == "Remove"
                end
            finally
                close(socket)
            end
        end
    end

    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "partial-frame"))
    take_deadline(partial_sent; message = "partial frame sent")
    started = time()
    failure = next_update(subscription; timeout = 4)
    @test failure.error.kind == :transport
    @test occursin("partial progress", failure.error.message)
    @test time() - started < 3.5
    @test take_deadline(
        peer_retired;
        timeout = 1,
        message = "client-owned partial frame retirement",
    ) < 3.5
    recovered = next_update(subscription; timeout = 4)
    @test recovered.error === nothing
    @test recovered.value["count"] == 1
    @test length(records) == 2
    @test records[2]["connectionCount"] == 1
    unsubscribe!(subscription)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "handshake and owner write deadlines" begin
    # The peer stays open past the assertion, so only the client's handshake
    # timer can release the transport-barrier subscribe call.
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    accepted = Channel{Nothing}(1)
    release_handshake = Channel{Nothing}(1)
    stalled_handshake = @async begin
        socket = accept(listener)
        put!(accepted, nothing)
        take_deadline(
            release_handshake;
            timeout = Convex.HANDSHAKE_TIMEOUT_SECONDS + 3,
            message = "release handshake",
        )
        close(socket)
        close(listener)
    end
    client = Client("http://127.0.0.1:$(address[2])")
    started = time()
    subscribe_result = Channel{Any}(1)
    subscriber = @async put!(
        subscribe_result,
        try
            subscribe(client, "demo:state", Dict("room" => "handshake"))
        catch error
            error
        end,
    )
    take_deadline(accepted; message = "stalled handshake accept")
    # Measure the response-read deadline after the peer has accepted the TCP
    # connection, excluding cold compilation and connect scheduling.
    started = time()
    result = take_deadline(
        subscribe_result;
        timeout = Convex.HANDSHAKE_TIMEOUT_SECONDS + 0.75,
        message = "client handshake deadline",
    )
    if result isa ConvexError
        @test result.kind == :transport
    else
        @test false # subscribe crossed the handshake barrier without an upgrade
    end
    handshake_assertion_deadline = started + Convex.HANDSHAKE_TIMEOUT_SECONDS + 0.75
    wait_until(
        () -> isempty(client.live.subscriptions);
        timeout = max(0.01, handshake_assertion_deadline - time()),
        message = "cancelled handshake state cleanup",
    )
    @test time() < handshake_assertion_deadline
    @test isempty(client.live.subscriptions)
    put!(release_handshake, nothing)
    wait(stalled_handshake)
    wait(subscriber)
    started = time()
    close!(client)
    @test time() - started < Convex.CLOSE_TIMEOUT_SECONDS

    # Advertise a tiny receive window before the upgrade and never read the
    # client's Connect/Add. The peer remains open until after the deadline.
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    upgraded = Channel{Nothing}(1)
    release_write = Channel{Nothing}(1)
    stalled_write = @async begin
        socket = accept(listener)
        receive_bytes = Ref{Cint}(4096)
        ccall(
            :setsockopt,
            Cint,
            (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
            Convex.socket_descriptor(socket),
            1,
            8,
            receive_bytes,
            sizeof(receive_bytes[]),
        ) == 0 || error("fixture could not shrink receive window")
        server_handshake(socket)
        put!(upgraded, nothing)
        take_deadline(
            release_write;
            timeout = Convex.WRITE_TIMEOUT_SECONDS + 3,
            message = "release write stall",
        )
        close(socket)
        close(listener)
    end
    client = Client("http://127.0.0.1:$(address[2])")
    padding = repeat("w", Convex.MAX_SUBSCRIPTION_BYTES - 4096)
    subscribe_result = Channel{Any}(1)
    started = time()
    subscriber = @async put!(
        subscribe_result,
        try
            subscribe(client, "demo:state", Dict("padding" => padding))
        catch error
            error
        end,
    )
    take_deadline(upgraded; message = "stalled write upgrade")
    write_started = time()
    result = take_deadline(
        subscribe_result;
        timeout = Convex.WRITE_TIMEOUT_SECONDS + 0.75,
        message = "owner write deadline",
    )
    if result isa ConvexError
        @test result.kind == :transport
    else
        @test false # subscribe crossed the Add barrier while its peer was stalled
    end
    @test time() - write_started < Convex.WRITE_TIMEOUT_SECONDS + 0.75
    @test isempty(client.live.subscriptions)
    put!(release_write, nothing)
    wait(stalled_write)
    wait(subscriber)
    close!(client)
end

@testset "malformed protocol reconnects and later recovers" begin
    records = Any[]
    url, fixture, fixture_errors = fixture_listener() do listener
        for connection = 1:7
            socket = accept(listener)
            try
                server_handshake(socket)
                connect = read_client_json(socket)
                add = read_client_json(socket)
                push!(records, connect)
                id = Int(add["modifications"][1]["queryId"])
                if connection == 1
                    send_frame(socket, 0x01, UInt8[0xff])
                elseif connection == 2
                    send_text(socket, 7)
                elseif connection == 3
                    try
                        write(
                            socket,
                            long_frame_bytes(
                                0x01,
                                fill(UInt8('x'), Convex.MAX_LIVE_BYTES + 1),
                            ),
                        )
                        flush(socket)
                    catch error
                        error isa Base.IOError || rethrow()
                    end
                elseif connection == 4
                    malformed = transition(
                        0,
                        1,
                        0,
                        9,
                        [updated(id, 9), updated(id, 10; logs = Any["valid", 42])],
                    )
                    send_text(socket, malformed)
                elseif connection == 5
                    malformed = transition(0, 1, 0, 9, [updated(id, 9)])
                    malformed["startVersion"] = 7
                    send_text(socket, malformed)
                elseif connection == 6
                    send_text(socket, transition(0, 1, 0, 9, Any[7]))
                else
                    send_text(socket, transition(0, 1, 0, 1, [updated(id, 1)]))
                end
                try
                    while true
                        read(socket, UInt8)
                    end
                catch
                end
            finally
                close(socket)
            end
        end
    end
    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "protocol-recovery"))
    @test next_update(subscription).error.kind == :protocol
    @test next_update(subscription).error.kind == :protocol
    @test next_update(subscription).error.kind == :protocol
    @test next_update(subscription).error.kind == :protocol
    @test next_update(subscription).error.kind == :protocol
    @test next_update(subscription).error.kind == :protocol
    @test next_update(subscription).value["count"] == 1
    @test records[7]["connectionCount"] == 6
    # The rejected transition's timestamp 9 was never committed.
    @test !haskey(records[7], :maxObservedTimestamp)
    unsubscribe!(subscription)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

@testset "unexpected transport drop reports and later recovers" begin
    url, fixture, fixture_errors = fixture_listener() do listener
        for connection = 1:2
            socket = accept(listener)
            server_handshake(socket)
            read_client_json(socket)
            add = read_client_json(socket)
            id = Int(add["modifications"][1]["queryId"])
            send_text(
                socket,
                transition(0, 1, 0, connection, [updated(id, connection - 1)]),
            )
            if connection == 1
                send_frame(socket, 0x08, UInt8[0x03, 0xe8])
                sleep(0.05)
                close(socket)
            else
                try
                    while true
                        read(socket, UInt8)
                    end
                catch
                end
                close(socket)
            end
        end
    end
    client = Client(url)
    subscription = subscribe(client, "demo:state", Dict("room" => "transport-recovery"))
    @test next_update(subscription).value["count"] == 0
    @test next_update(subscription).error.kind == :transport
    @test next_update(subscription).value["count"] == 1
    unsubscribe!(subscription)
    close!(client)
    finish_fixture(fixture, fixture_errors)
end

function read_ndjson(socket; timeout = TEST_TIMEOUT)
    reader = @async begin
        bytes = UInt8[]
        while true
            byte = read(socket, UInt8)
            byte == UInt8('\n') && return JSON3.read(String(bytes))
            push!(bytes, byte)
        end
    end
    timedwait(() -> istaskdone(reader), timeout; pollint = 0.002) == :ok ||
        error("timed out waiting for adapter output")
    return fetch(reader)
end

function socket_read_ready(socket, timeout_ms::Int)
    descriptor = Convex.socket_descriptor(socket)
    poll_descriptor = Ref(Convex.PollDescriptor(descriptor, Cshort(0x001), Cshort(0)))
    return ccall(
        :poll,
        Cint,
        (Ptr{Convex.PollDescriptor}, Culong, Cint),
        poll_descriptor,
        1,
        timeout_ms,
    ) > 0
end

@testset "adapter partial NDJSON, malformed isolation, UTF-8, EOF cleanup" begin
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    adapter_done = Channel{Any}(1)
    adapter = @async begin
        socket = accept(listener)
        close(listener)
        try
            run_adapter(socket, socket)
            put!(adapter_done, nothing)
        catch error
            put!(adapter_done, error)
        finally
            close(socket)
        end
    end
    controller = connect(ip"127.0.0.1", address[2])
    hello = Vector{UInt8}("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n")
    for part in (hello[1:4], hello[5:17], hello[18:end])
        write(controller, part)
        flush(controller)
        sleep(0.002)
    end
    @test read_ndjson(controller)["type"] == "ready"
    # The first bounded TCP output must not leave the shared descriptor in
    # nonblocking mode. A second split command should wait for its suffix and
    # then parse normally after that output write.
    again =
        Vector{UInt8}("{\"protocolVersion\":1,\"id\":\"after-write\",\"op\":\"hello\"}\n")
    write(controller, again[1:19])
    flush(controller)
    sleep(0.01)
    @test !socket_read_ready(controller, 20)
    write(controller, again[20:end])
    flush(controller)
    @test read_ndjson(controller)["id"] == "after-write"
    write(controller, "{bad json}\n")
    write(controller, UInt8[0xff, 0x0a])
    write(controller, repeat("x", MAX_NDJSON_BYTES + 1) * "\n")
    write(controller, "null\n[]\n\"scalar\"\n7\n")
    write(controller, "{\"protocolVersion\":1,\"id\":\"again\",\"op\":\"hello\"}\n")
    flush(controller)
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["error"]["name"] == "ProtocolError"
    @test read_ndjson(controller)["id"] == "again"
    close(controller)
    wait_until(() -> isready(adapter_done); message = "adapter EOF cleanup")
    @test take_deadline(adapter_done; message = "adapter completion") === nothing
    wait(adapter)
end

@testset "stdin stream partial UTF-8, malformed bounds, and EOF" begin
    input = Base.BufferStream()
    output = IOBuffer()
    completed = Channel{Any}(1)
    adapter = @async put!(completed, try
        run_adapter(input, output)
        nothing
    catch error
        error
    end)
    hello = Vector{UInt8}(
        JSON3.write(Dict("protocolVersion" => 1, "id" => "héllo", "op" => "hello")) * "\n",
    )
    split_at = findfirst(==(UInt8(0xc3)), hello)
    write(input, hello[1:split_at])
    flush(input)
    write(input, hello[(split_at+1):end])
    write(input, "{bad json}\n")
    write(input, repeat("x", MAX_NDJSON_BYTES + 1), "\n")
    write(input, "null\n")
    flush(input)
    close(input)
    @test take_deadline(completed; timeout = 5, message = "stdin adapter EOF") === nothing
    wait(adapter)
    events =
        [JSON3.read(line) for line in split(String(take!(output)), '\n') if !isempty(line)]
    @test events[1][:type] == "ready"
    @test events[1][:id] == "héllo"
    @test [event[:error][:name] for event in events[2:end]] == fill("ProtocolError", 3)
end

@testset "adapter EOF closes sixteen subscriptions with one bounded owner barrier" begin
    peer_retired = Channel{Nothing}(1)
    url, fixture, fixture_errors = fixture_listener() do listener
        socket = accept(listener)
        try
            server_handshake(socket)
            read_client_json(socket)
            for _ = 1:Convex.MAX_SUBSCRIPTIONS
                add = read_client_json(socket)
                @test add["modifications"][1]["type"] == "Add"
            end
            try
                while true
                    read(socket, UInt8)
                end
            catch
            end
            put!(peer_retired, nothing)
        finally
            close(socket)
        end
    end

    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    adapter_done = Channel{Any}(1)
    old_url = get(ENV, "CONVEX_URL", nothing)
    ENV["CONVEX_URL"] = url
    adapter = @async begin
        socket = accept(listener)
        close(listener)
        try
            run_adapter(socket, socket)
            put!(adapter_done, nothing)
        catch error
            put!(adapter_done, error)
        finally
            close(socket)
        end
    end
    controller = connect(ip"127.0.0.1", address[2])
    try
        write(
            controller,
            JSON3.write(Dict("protocolVersion" => 1, "id" => "h", "op" => "hello")),
            "\n",
        )
        flush(controller)
        @test read_ndjson(controller)[:type] == "ready"
        for index = 1:Convex.MAX_SUBSCRIPTIONS
            write(
                controller,
                JSON3.write(
                    Dict(
                        "id" => "s$(index)",
                        "op" => "subscribe",
                        "subscriptionId" => "sub$(index)",
                        "path" => "demo:state",
                        "args" => Dict("index" => index),
                    ),
                ),
                "\n",
            )
            flush(controller)
            @test read_ndjson(controller)[:id] == "s$(index)"
        end
        started = time()
        close(controller)
        @test take_deadline(
            adapter_done;
            timeout = 2,
            message = "sixteen-subscription adapter EOF",
        ) === nothing
        @test time() - started < 2
        take_deadline(peer_retired; timeout = 1, message = "EOF peer retirement")
    finally
        close(controller)
        isnothing(old_url) ? delete!(ENV, "CONVEX_URL") : (ENV["CONVEX_URL"] = old_url)
    end
    wait(adapter)
    finish_fixture(fixture, fixture_errors)
end

@testset "real adapter relay barriers after dequeue" begin
    fail_peer = Channel{Nothing}(1)
    value_update(id, label) = Dict(
        "type" => "QueryUpdated",
        "queryId" => id,
        "value" => Dict("label" => label),
        "logLines" => String[],
    )
    url, fixture, fixture_errors = fixture_listener() do listener
        labels = ("stale-unsubscribe", "stale-replacement", "new-generation")
        for (connection, label) in enumerate(labels)
            socket = accept(listener)
            try
                server_handshake(socket)
                read_client_json(socket)
                add = read_client_json(socket)
                id = Int(add["modifications"][1]["queryId"])
                send_text(socket, transition(0, 1, 0, 1, [value_update(id, label)]))
                if connection < 3
                    remove = read_client_json(socket)
                    @test remove["modifications"][1]["queryId"] == id
                else
                    take_deadline(fail_peer; message = "adapter failed-peer close")
                end
            finally
                close(socket)
            end
        end
    end

    adapter_listener = listen(ip"127.0.0.1", 0)
    adapter_address = getsockname(adapter_listener)
    adapter_done = Channel{Any}(1)
    old_url = get(ENV, "CONVEX_URL", nothing)
    ENV["CONVEX_URL"] = url
    dequeued = Channel{Any}(4)
    release_relay = Channel{Nothing}(4)
    TEST_RELAY_DEQUEUED[] = dequeued
    TEST_RELAY_RELEASE[] = release_relay
    adapter = @async begin
        socket = accept(adapter_listener)
        close(adapter_listener)
        try
            run_adapter(socket, socket)
            put!(adapter_done, nothing)
        catch error
            put!(adapter_done, error)
        finally
            close(socket)
        end
    end
    controller = connect(ip"127.0.0.1", adapter_address[2])
    try
        write(controller, "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n")
        flush(controller)
        @test read_ndjson(controller)[:type] == "ready"

        write(
            controller,
            "{\"id\":\"sub0\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}\n",
        )
        flush(controller)
        @test read_ndjson(controller)[:id] == "sub0"
        @test take_deadline(dequeued; message = "unsubscribe relay dequeue") == ("same", 1)
        write(
            controller,
            "{\"id\":\"unsub0\",\"op\":\"unsubscribe\",\"subscriptionId\":\"same\"}\n",
        )
        flush(controller)
        @test read_ndjson(controller)[:id] == "unsub0"
        put!(release_relay, nothing)
        @test !socket_read_ready(controller, 50)

        write(
            controller,
            "{\"id\":\"sub1\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}\n",
        )
        flush(controller)
        @test read_ndjson(controller)[:id] == "sub1"
        replacement_dequeued =
            take_deadline(dequeued; message = "replacement relay dequeue")
        @test replacement_dequeued == ("same", 2)
        write(
            controller,
            "{\"id\":\"replace\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{\"generation\":2}}\n",
        )
        flush(controller)
        @test read_ndjson(controller)[:id] == "replace"
        put!(release_relay, nothing)
        @test take_deadline(dequeued; message = "new generation relay dequeue") ==
              ("same", 3)
        put!(release_relay, nothing)
        event = read_ndjson(controller; timeout = 2)
        @test event[:subscriptionId] == "same"
        @test event[:value][:label] == "new-generation"
        @test !socket_read_ready(controller, 50)

        TEST_RELAY_DEQUEUED[] = nothing
        TEST_RELAY_RELEASE[] = nothing
        put!(fail_peer, nothing)
        sleep(0.05)
        # EOF with a failed peer and an active subscription must unwind the
        # client, owner, relay, and output writer without a close command.
        close(controller)
    finally
        close(controller)
        TEST_RELAY_DEQUEUED[] = nothing
        TEST_RELAY_RELEASE[] = nothing
        isnothing(old_url) ? delete!(ENV, "CONVEX_URL") : (ENV["CONVEX_URL"] = old_url)
    end
    @test take_deadline(adapter_done; message = "relay barrier adapter cleanup") === nothing
    wait(adapter)
    finish_fixture(fixture, fixture_errors)
end

@testset "adapter output generation barrier and stopped-reader budget" begin
    output = IOBuffer()
    pump = OutputPump(output; interrupt_on_failure = false)
    activate_and_ack!(pump, "same", 1, "first")
    paused = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    relay = @async begin
        put!(paused, nothing)
        take_deadline(release; message = "relay release")
        write_event(
            pump,
            Dict(
                "type" => "subscription",
                "subscriptionId" => "same",
                "value" => Dict("old" => true),
            );
            subscription_id = "same",
            generation = 1,
        )
    end
    take_deadline(paused; message = "paused relay")
    activate_and_ack!(pump, "same", 2, "replacement")
    put!(release, nothing)
    wait(relay)
    for index = 1:40
        write_event(
            pump,
            Dict(
                "type" => "subscription",
                "subscriptionId" => "same",
                "value" =>
                    Dict("index" => index, "padding" => repeat("z", 1024 * 1024 - 512)),
            );
            subscription_id = "same",
            generation = 2,
        )
    end
    lock(pump.lock) do
        @test pump.buffered_items <= MAX_OUTPUT_ITEMS
        @test pump.encoded_bytes <= MAX_OUTPUT_BYTES
    end
    @test stop_output!(pump; timeout = 3)
    records =
        [JSON3.read(line) for line in split(String(take!(output)), '\n') if !isempty(line)]
    replacement_index =
        findfirst(record -> get(record, :id, nothing) == "replacement", records)
    @test !isnothing(replacement_index)
    @test all(
        record -> !(
            get(record, :subscriptionId, nothing) == "same" &&
            haskey(record, :value) &&
            get(record[:value], :old, false)
        ),
        records[replacement_index:end],
    )
end

@testset "global relay dispatcher bounds sixteen subscriptions under backpressure" begin
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    accepted = Channel{Any}(1)
    server = @async put!(accepted, accept(listener))
    stopped_reader = connect(ip"127.0.0.1", address[2])
    output_socket = take_deadline(accepted; message = "global relay stopped-reader accept")
    close(listener)

    # Make a stopped peer exert pressure after a small number of real writes.
    send_buffer = Ref{Cint}(4096)
    descriptor = Convex.socket_descriptor(output_socket)
    GC.@preserve send_buffer begin
        @test ccall(
            :setsockopt,
            Cint,
            (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
            descriptor,
            1, # SOL_SOCKET
            7, # SO_SNDBUF
            send_buffer,
            sizeof(Cint),
        ) == 0
    end

    pump = OutputPump(output_socket; interrupt_on_failure = false)
    budget = Convex.QueueBudget()
    subscriptions = Dict{String,Any}()
    padding = repeat("g", 512 * 1024 - 1024)
    for index = 1:16
        subscription =
            Convex.Subscription(nothing, index, 1, Convex.QueuedUpdate[], budget, false)
        subscription_id = "global-$(index)"
        subscriptions[subscription_id] = (subscription = subscription, generation = 1)
        lock(pump.lock) do
            pump.active_generations[subscription_id] = 1
        end
        Convex.deliver!(
            subscription,
            LiveUpdate(Dict("index" => index, "padding" => padding), nothing, String[]),
        )
    end
    @test length(subscriptions) == 16
    @test length(budget.order) == Convex.MAX_QUEUE_ITEMS

    dequeued = Channel{Any}(16)
    release_relay = Channel{Nothing}(1)
    TEST_RELAY_DEQUEUED[] = dequeued
    TEST_RELAY_RELEASE[] = release_relay
    relay_closing = Ref(false)
    dispatcher = @async relay_subscriptions(pump, subscriptions, relay_closing)
    try
        take_deadline(dequeued; message = "global relay single dequeue")
        sleep(0.02)
        # One dispatcher means the other fifteen subscriptions cannot each
        # retain a dequeued value while this one is deliberately paused.
        @test !isready(dequeued)
        lock(budget.lock) do
            lock(pump.lock) do
                @test length(budget.order) + pump.buffered_items + MAX_TRANSIENT_ITEMS <= 16
                @test budget.encoded_bytes +
                      pump.encoded_bytes +
                      MAX_TRANSIENT_ENCODED_BYTES <= 14 * 1024 * 1024
            end
        end

        TEST_RELAY_DEQUEUED[] = nothing
        TEST_RELAY_RELEASE[] = nothing
        put!(release_relay, nothing)
        wait_until(
            () -> lock(budget.lock) do
                lock(pump.lock) do
                    isempty(budget.order) || pump.buffered_items > 0
                end
            end;
            message = "global relay output progress",
        )
        lock(budget.lock) do
            lock(pump.lock) do
                # Count relay, decoder, and both candidate encodings even when
                # they are not observed at this instant.
                @test length(budget.order) + pump.buffered_items + MAX_TRANSIENT_ITEMS <= 16
                @test budget.encoded_bytes +
                      pump.encoded_bytes +
                      MAX_TRANSIENT_ENCODED_BYTES <= 14 * 1024 * 1024
            end
        end
    finally
        TEST_RELAY_DEQUEUED[] = nothing
        TEST_RELAY_RELEASE[] = nothing
        relay_closing[] = true
        close(stopped_reader)
    end
    @test timedwait(() -> istaskdone(dispatcher), 0.5; pollint = 0.002) == :ok
    @test stop_output!(pump)
    close(output_socket)
    wait(server)
end


@testset "serialized subscription and command error shapes" begin
    output = IOBuffer()
    pump = OutputPump(output; interrupt_on_failure = false)
    lock(pump.lock) do
        pump.active_generations["shape"] = 1
    end
    failure(
        pump,
        nothing,
        ConvexError(:function_error, "query failed", Dict("code" => "E"), ["query log"]);
        subscription_id = "shape",
        generation = 1,
    )
    failure(pump, "protocol-id", ConvexError(:protocol, "bad command", nothing, String[]))
    failure(
        pump,
        "transport-id",
        ConvexError(:transport, "socket failed", nothing, String[]),
    )
    wait_until(
        () -> lock(pump.lock) do
            pump.buffered_items == 0
        end;
        message = "serialized error output drain",
    )
    @test stop_output!(pump; timeout = 2)
    events =
        [JSON3.read(line) for line in split(String(take!(output)), '\n') if !isempty(line)]
    subscription_error = events[1]
    @test subscription_error[:type] == "subscription"
    @test subscription_error[:subscriptionId] == "shape"
    @test subscription_error[:error][:name] == "FunctionError"
    @test subscription_error[:logs] == ["query log"]
    @test !haskey(subscription_error, :id)
    @test !haskey(subscription_error, :value)
    @test events[2][:id] == "protocol-id"
    @test events[2][:error][:name] == "ProtocolError"
    @test events[3][:id] == "transport-id"
    @test events[3][:error][:name] == "TransportError"
end

@testset "bounded adapter write expires despite positive slow-drain progress" begin
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    accepted = Channel{Any}(1)
    accept_task = @async put!(accepted, accept(listener))
    reader = connect(ip"127.0.0.1", address[2])
    writer = take_deadline(accepted; message = "slow-drain writer accept")
    close(listener)

    send_buffer = Ref{Cint}(4096)
    descriptor = Convex.socket_descriptor(writer)
    GC.@preserve send_buffer begin
        @test ccall(
            :setsockopt,
            Cint,
            (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
            descriptor,
            1,
            7,
            send_buffer,
            sizeof(Cint),
        ) == 0
    end
    drained = Ref(0)
    drain_task = @async try
        while isopen(reader)
            if socket_read_ready(reader, 10)
                available = max(1, min(bytesavailable(reader), 512))
                drained[] += length(read(reader, available))
                sleep(0.008)
            end
        end
    catch
    end
    payload = fill(UInt8('s'), 2 * 1024 * 1024)
    started = time()
    error = try
        bounded_write(writer, payload; timeout = 0.12)
        nothing
    catch caught
        caught
    end
    elapsed = time() - started
    @test error isa ConvexError
    @test error.kind == :transport
    @test 0 < drained[] < length(payload)
    @test elapsed < 0.4
    close(writer)
    close(reader)
    wait(drain_task)
    wait(accept_task)
end

@testset "real stopped socket reader keeps output count and bytes bounded" begin
    listener = listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    accepted = Channel{Any}(1)
    server = @async put!(accepted, accept(listener))
    stopped_reader = connect(ip"127.0.0.1", address[2])
    output_socket = take_deadline(accepted; message = "stopped-reader accept")
    close(listener)
    tiny_buffer = Ref{Cint}(4096)
    for (socket, option) in ((stopped_reader, 8), (output_socket, 7))
        @test ccall(
            :setsockopt,
            Cint,
            (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
            Convex.socket_descriptor(socket),
            1,
            option,
            tiny_buffer,
            sizeof(tiny_buffer[]),
        ) == 0
    end
    pump = OutputPump(output_socket; interrupt_on_failure = false)
    lock(pump.lock) do
        pump.active_generations["slow"] = 1
    end
    padding = repeat("m", Convex.MAX_LIVE_BYTES - 2048)
    for index = 1:12
        write_event(
            pump,
            Dict(
                "type" => "subscription",
                "subscriptionId" => "slow",
                "value" => Dict("index" => index, "padding" => padding),
            );
            subscription_id = "slow",
            generation = 1,
        )
    end
    lock(pump.lock) do
        @test pump.buffered_items <= MAX_OUTPUT_ITEMS
        @test pump.encoded_bytes <= MAX_OUTPUT_BYTES
    end
    started = time()
    wait_until(
        () -> pump.failed;
        timeout = 4,
        message = "bounded stopped-reader write failure",
    )
    # The deadline is cumulative across records, so a permanently unread peer
    # retires the writer in about a second however much is queued behind it.
    @test time() - started < 3 * OUTPUT_STALL_SECONDS
    # A connected peer that never reads is a stall, not a vanished peer.
    @test pump.stalled
    @test stop_output!(pump)
    # Every byte and slot the failed writer was holding must be released, or a
    # later event would be refused by a budget that is permanently reserved.
    lock(pump.lock) do
        @test pump.encoded_bytes == 0
        @test pump.buffered_items == 0
        @test isempty(pump.queue)
    end
    close(output_socket)
    close(stopped_reader)
    wait(server)
end

@testset "process-wide admission bounds in-flight near-maximum work" begin
    admission = Admission()
    @test try_admit!(admission, Convex.MAX_HTTP_BYTES)
    # One near-maximum payload is the whole budget: the next caller waits
    # rather than let a second near-maximum value exist inside the limit.
    @test !try_admit!(admission, Convex.MAX_HTTP_BYTES)
    @test admission.items == MAX_INFLIGHT_ITEMS
    @test admission.bytes == MAX_INFLIGHT_BYTES
    release!(admission, Convex.MAX_HTTP_BYTES)
    @test admission.items == 0
    @test admission.bytes == 0

    # A byte budget bounds admission even when the item count would allow it.
    small = Admission()
    @test try_admit!(small, MAX_INFLIGHT_BYTES)
    @test !try_admit!(small, 1)
    release!(small, MAX_INFLIGHT_BYTES)
    @test small.items == 0
    @test small.bytes == 0

    # Blocking admission is deadline bounded, and a caller that times out must
    # not leave a reservation behind.
    saturated = Admission()
    @test try_admit!(saturated, Convex.MAX_HTTP_BYTES)
    started = time()
    denied = try
        admit!(saturated, Convex.MAX_HTTP_BYTES; timeout = 0.05)
        nothing
    catch caught
        caught
    end
    @test denied isa ConvexError
    @test denied.kind == :transport
    @test time() - started < 1
    @test saturated.items == MAX_INFLIGHT_ITEMS
    @test saturated.bytes == MAX_INFLIGHT_BYTES
    release!(saturated, Convex.MAX_HTTP_BYTES)
    @test saturated.items == 0
    @test saturated.bytes == 0

    # A waiter admitted only once room appears still leaves the budget clean.
    handoff = Admission()
    @test try_admit!(handoff, Convex.MAX_HTTP_BYTES)
    waiter = @async try
        admit!(handoff, Convex.MAX_HTTP_BYTES; timeout = TEST_TIMEOUT)
        :admitted
    catch caught
        caught
    end
    sleep(0.05)
    @test !istaskdone(waiter)
    release!(handoff, Convex.MAX_HTTP_BYTES)
    @test fetch(waiter) === :admitted
    release!(handoff, Convex.MAX_HTTP_BYTES)
    @test handoff.items == 0
    @test handoff.bytes == 0
end

@testset "adapter status separates a clean close from a stalled controller" begin
    input = IOBuffer(
        "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n" *
        "{\"id\":\"close\",\"op\":\"close\"}\n",
    )
    @test run_adapter(input, IOBuffer()) === :closed
    # End of input is a clean session too: the controller simply went away.
    @test run_adapter(
        IOBuffer("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"),
        IOBuffer(),
    ) === :closed
    # Whatever happened, the process-wide budget must be fully released.
    @test ADMISSION.items == 0
    @test ADMISSION.bytes == 0

    # A writer that hit its cumulative deadline must be reported, not flattened
    # into a successful close.
    output = IOBuffer()
    pump = OutputPump(output; interrupt_on_failure = false)
    lock(pump.lock) do
        pump.stalled = true
    end
    @test stop_output!(pump)
    @test pump.stalled
end
