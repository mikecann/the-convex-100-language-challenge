module Convex

using Base64
using HTTP
using JSON3
using OpenSSL
using Random
using SHA
using Sockets
using UUIDs

export Client,
    Result,
    LiveUpdate,
    ConvexError,
    query,
    mutation,
    action,
    subscribe,
    next_update,
    unsubscribe!,
    close!,
    set_auth!,
    debug_disconnect_for_adapter,
    whole_count

const MAX_HTTP_BYTES = 2 * 1024 * 1024
const MAX_LIVE_BYTES = 2 * 1024 * 1024
const MAX_SUBSCRIPTIONS = 16
# Reserve room for the ModifyQuerySet envelope, query IDs, and JSON escaping
# when all retained Add records are replayed together after reconnect.
const MAX_SUBSCRIPTION_BYTES = MAX_LIVE_BYTES - 64 * 1024
# The adapter has its own bounded output stage. Five retained client records
# leave count reserve for its writer, relay, decoder, and both candidate
# encodings rather than pretending transient construction costs are free.
const MAX_QUEUE_ITEMS = 5
const MAX_QUEUE_BYTES = 3 * 1024 * 1024
const NETWORK_READ_CHUNK = 64 * 1024
const NETWORK_WRITE_CHUNK = 2 * 1024
const HANDSHAKE_TIMEOUT_SECONDS = 5
const WRITE_TIMEOUT_SECONDS = 2
const TLS_RECORD_TIMEOUT_SECONDS = 2.0
const FRAME_STALL_TIMEOUT_SECONDS = 2.0
const CLOSE_TIMEOUT_SECONDS = 7.0
const OWNER_COMMAND_GRACE_SECONDS = WRITE_TIMEOUT_SECONDS + 1.0
const INITIAL_BACKOFF_SECONDS = 0.1
const MAX_BACKOFF_SECONDS = 15.0
const CLIENT_VERSION = "julia-0.1.0"
const MAX_CLOSE_REASON_BYTES = 512

"""A typed error preserves whether Convex or its transport rejected an operation."""
struct ConvexError <: Exception
    kind::Symbol
    message::String
    data::Any
    logs::Vector{String}
end
Base.showerror(io::IO, error::ConvexError) = print(io, error.kind, ": ", error.message)

struct Result
    value::Any
    logs::Vector{String}
end

struct LiveUpdate
    value::Any
    error::Union{Nothing,ConvexError}
    logs::Vector{String}
end

mutable struct QueuedUpdate
    owner::Any
    update::LiveUpdate
    encoded_bytes::Int
end

mutable struct QueueBudget
    lock::ReentrantLock
    order::Vector{QueuedUpdate}
    encoded_bytes::Int
end
QueueBudget() = QueueBudget(ReentrantLock(), QueuedUpdate[], 0)

mutable struct Subscription
    manager::Any
    query_id::Int
    generation::Int
    queue::Vector{QueuedUpdate}
    budget::QueueBudget
    finished::Bool
end

mutable struct OwnerCommand
    parts::Tuple
    reply::Channel{Any}
    lock::ReentrantLock
    deadline::Float64
    cancelled::Bool
    claimed::Bool
    completed::Bool
end

OwnerCommand(parts::Tuple, reply::Channel{Any}, deadline::Real) =
    OwnerCommand(parts, reply, ReentrantLock(), Float64(deadline), false, false, false)

mutable struct FrameParser
    bytes::Vector{UInt8}
    fragmented_opcode::UInt8
    fragmented_payload::Vector{UInt8}
    tls_wants_write::Bool
    tls_retry_read::Bool
    tls_stall_deadline::Float64
    frame_stall_deadline::Float64
end
FrameParser() = FrameParser(UInt8[], 0x00, UInt8[], false, false, 0.0, 0.0)

struct PollDescriptor
    descriptor::Cint
    events::Cshort
    returned_events::Cshort
end

mutable struct LiveManager
    websocket_url::String
    client_version::String
    commands::Channel{Any}
    command_lock::ReentrantLock
    subscriptions::Dict{Int,Any}
    remote_values::Dict{Int,Vector{UInt8}}
    last_delivered::Dict{Int,Tuple{Symbol,Vector{UInt8}}}
    pending_hydration::Set{Int}
    budget::QueueBudget
    subscription_bytes::Int
    next_query_id::Int
    query_set_version::Int
    remote_version::Any
    connection_count::Int
    last_close_reason::String
    max_observed_timestamp::Union{Nothing,String}
    max_observed_timestamp_value::UInt64
    next_backoff::Float64
    reconnect_at::Float64
    closing::Bool
    connected::Bool
    owner_task::Union{Nothing,Task}
    worker::Task
    supervisor::Task
end

mutable struct Client
    deployment_url::String
    auth_token::String
    client_version::String
    live::Union{Nothing,LiveManager}
    closed::Bool
    closing::Bool
    lock::ReentrantLock
end

# HTTP.jl deliberately owns its upgraded connection object. For plain ws://
# fixtures we keep the raw socket instead, which lets the same Live owner bound
# the HTTP Upgrade read without a detached timeout task.
struct RawConnection <: IO
    io::TCPSocket
end

Base.isopen(connection::RawConnection) = isopen(connection.io)
Base.close(connection::RawConnection) = close(connection.io)
Base.flush(connection::RawConnection) = flush(connection.io)
Base.unsafe_write(connection::RawConnection, pointer::Ptr{UInt8}, count::UInt) =
    Base.unsafe_write(connection.io, pointer, count)

mutable struct RawWebSocket
    io::RawConnection
    buffer::Vector{UInt8}
    client::Bool
    readclosed::Bool
    writeclosed::Bool
end

HTTP.IOExtras.tcpsocket(websocket::RawWebSocket) = websocket.io.io

zero_version() =
    (query_set = 0, identity = 0, timestamp = UInt64(0), encoded_timestamp = "AAAAAAAAAAA=")

function Client(
    url::AbstractString;
    auth_token::AbstractString = "",
    client_version::AbstractString = CLIENT_VERSION,
)
    uri = HTTP.URI(String(url))
    uri.scheme in ("http", "https") ||
        throw(ArgumentError("Convex URL must use http or https"))
    isempty(uri.host) && throw(ArgumentError("Convex URL needs a host"))
    isempty(uri.userinfo) ||
        throw(ArgumentError("Convex URL must not contain user information"))
    isempty(uri.query) || throw(ArgumentError("Convex URL must not contain a query"))
    isempty(uri.fragment) || throw(ArgumentError("Convex URL must not contain a fragment"))
    host = occursin(':', uri.host) ? "[" * uri.host * "]" : uri.host
    port = isempty(string(uri.port)) ? "" : ":" * string(uri.port)
    clean =
        replace(string(uri.scheme, "://", host, port, rstrip(uri.path, '/')), r"/$" => "")
    return Client(
        clean,
        String(auth_token),
        String(client_version),
        nothing,
        false,
        false,
        ReentrantLock(),
    )
end

function set_auth!(client::Client, token::AbstractString)
    lock(client.lock) do
        (client.closed || client.closing) && throw(
            ConvexError(:closed, "Convex client is closing or closed", nothing, String[]),
        )
        client.auth_token = String(token)
    end
    return nothing
end

query(client::Client, path::AbstractString, args::AbstractDict = Dict{String,Any}()) =
    call(client, "query", path, args)
mutation(client::Client, path::AbstractString, args::AbstractDict = Dict{String,Any}()) =
    call(client, "mutation", path, args)
action(client::Client, path::AbstractString, args::AbstractDict = Dict{String,Any}()) =
    call(client, "action", path, args)

function call(client::Client, operation::String, path::AbstractString, args::AbstractDict)
    operation in ("query", "mutation", "action") ||
        throw(ArgumentError("unknown Convex operation"))
    isempty(path) && throw(ArgumentError("Convex function path is required"))
    # Every public entry point stores one concrete args tree so PackageCompiler
    # with --strip-ir only needs one Live/HTTP specialization, not one per
    # Dict{String,String} vs adapter Dict{String,Any}/JSON3.Object shape.
    canonical_args = canonicalize_args(args)
    body = JSON3.write(
        Dict{String,Any}(
            "path" => String(path),
            "args" => canonical_args,
            "format" => "json",
        ),
    )
    ncodeunits(body) <= MAX_HTTP_BYTES ||
        throw(ConvexError(:protocol, "HTTP request exceeds byte limit", nothing, String[]))
    token = lock(client.lock) do
        (client.closed || client.closing) && throw(
            ConvexError(:closed, "Convex client is closing or closed", nothing, String[]),
        )
        client.auth_token
    end
    headers = [
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Accept-Encoding" => "identity",
        "Convex-Client" => client.client_version,
        "Content-Length" => string(ncodeunits(body)),
    ]
    isempty(token) || push!(headers, "Authorization" => "Bearer " * token)
    response_status, response_body = try
        bounded_http_request(
            "POST",
            client.deployment_url * "/api/" * operation,
            headers,
            body;
            connect_timeout = 10,
            readtimeout = 30,
            retry = false,
        )
    catch error
        throw(typed_error(error, :transport))
    end
    200 <= response_status < 300 || throw(
        ConvexError(
            :transport,
            "Convex HTTP endpoint returned status $(response_status)",
            Dict("status" => response_status),
            String[],
        ),
    )
    decoded = try
        # Materialize into plain Julia containers instead of JSON3's lazy,
        # element-typed views. See public_value for why the view types are
        # unusable in a runtime that cannot compile new code.
        JSON3.read(String(response_body), Any)
    catch error
        throw(
            ConvexError(
                :protocol,
                "HTTP response was not JSON: " * sprint(showerror, error),
                nothing,
                String[],
            ),
        )
    end
    decoded isa AbstractDict || throw(
        ConvexError(:protocol, "HTTP response must be a JSON object", nothing, String[]),
    )
    status = jsonget(decoded, "status", nothing)
    logs = validated_logs(jsonget(decoded, "logLines", Any[]))
    if status == "success"
        jsonhas(decoded, "value") ||
            throw(ConvexError(:protocol, "success response omitted value", nothing, logs))
        return Result(public_value(jsonget(decoded, "value", nothing)), logs)
    elseif status == "error"
        message = jsonget(decoded, "errorMessage", "Convex function failed")
        message isa AbstractString ||
            throw(ConvexError(:protocol, "errorMessage must be a string", nothing, logs))
        throw(
            ConvexError(
                :function_error,
                String(message),
                public_value(jsonget(decoded, "errorData", nothing)),
                logs,
            ),
        )
    end
    throw(
        ConvexError(
            :protocol,
            "unexpected Convex HTTP status $(repr(status))",
            nothing,
            logs,
        ),
    )
end

function bounded_http_request(
    method,
    url,
    headers,
    body;
    connect_timeout,
    readtimeout,
    retry,
)
    status = Ref(0)
    response_body = UInt8[]
    HTTP.open(
        method,
        url,
        headers;
        connect_timeout,
        readtimeout,
        retry,
        status_exception = false,
    ) do stream
        write(stream, body)
        response = HTTP.startread(stream)
        status[] = Int(response.status)
        declared = HTTP.header(response, "Content-Length", "")
        if !isempty(declared)
            declared_bytes = tryparse(Int, declared)
            isnothing(declared_bytes) && throw(
                ConvexError(
                    :protocol,
                    "HTTP Content-Length was invalid",
                    nothing,
                    String[],
                ),
            )
            declared_bytes >= 0 || throw(
                ConvexError(
                    :protocol,
                    "HTTP Content-Length was negative",
                    nothing,
                    String[],
                ),
            )
            declared_bytes <= MAX_HTTP_BYTES || throw(
                ConvexError(
                    :transport,
                    "HTTP response exceeds byte limit",
                    nothing,
                    String[],
                ),
            )
        end
        while !eof(stream)
            chunk = read(
                stream,
                min(NETWORK_READ_CHUNK, MAX_HTTP_BYTES - length(response_body) + 1),
            )
            isempty(chunk) && continue
            length(response_body) + length(chunk) <= MAX_HTTP_BYTES || throw(
                ConvexError(
                    :transport,
                    "HTTP response exceeds byte limit",
                    nothing,
                    String[],
                ),
            )
            append!(response_body, chunk)
        end
    end
    return status[], response_body
end

function subscribe(
    client::Client,
    path::AbstractString,
    args::AbstractDict = Dict{String,Any}(),
)
    isempty(path) && throw(ArgumentError("Convex function path is required"))
    canonical_args = canonicalize_args(args)
    request_bytes = ncodeunits(
        JSON3.write(Dict{String,Any}("path" => String(path), "args" => canonical_args)),
    )
    request_bytes <= MAX_SUBSCRIPTION_BYTES || throw(
        ConvexError(
            :protocol,
            "Live subscription request exceeds byte limit",
            nothing,
            String[],
        ),
    )
    manager = lock(client.lock) do
        (client.closed || client.closing) && throw(
            ConvexError(:closed, "Convex client is closing or closed", nothing, String[]),
        )
        isnothing(client.live) &&
            (client.live = LiveManager(client.deployment_url, client.client_version))
        client.live
    end
    return manager_command(
        manager,
        (:subscribe, String(path), canonical_args, request_bytes);
        timeout = CLOSE_TIMEOUT_SECONDS,
    )
end

function unsubscribe!(subscription::Subscription)
    manager = subscription.manager::LiveManager
    manager_command(
        manager,
        (:unsubscribe, subscription.query_id, subscription.generation);
        timeout = CLOSE_TIMEOUT_SECONDS,
    )
    return nothing
end

function next_update(subscription::Subscription; timeout::Real = 10)
    deadline = time() + timeout
    while true
        update = lock(subscription.budget.lock) do
            if !isempty(subscription.queue)
                queued = popfirst!(subscription.queue)
                index = findfirst(item -> item === queued, subscription.budget.order)
                isnothing(index) || deleteat!(subscription.budget.order, index)
                subscription.budget.encoded_bytes -= queued.encoded_bytes
                return queued.update
            end
            subscription.finished && throw(
                ConvexError(:closed, "Live subscription is closed", nothing, String[]),
            )
            return nothing
        end
        update === nothing || return update
        time() >= deadline && throw(
            ConvexError(:transport, "timed out waiting for Live update", nothing, String[]),
        )
        sleep(0.002)
    end
end

function close!(client::Client)
    already_closed = lock(client.lock) do
        client.closed
    end
    already_closed && return nothing
    manager, already_closing = lock(client.lock) do
        was_closing = client.closing
        client.closing = true
        (client.live, was_closing)
    end
    if isnothing(manager)
        lock(client.lock) do
            client.closed = true
            client.closing = false
        end
        return nothing
    end
    try
        if !already_closing
            try
                manager_command(manager, (:close,); timeout = CLOSE_TIMEOUT_SECONDS)
            catch error
                # A worker that already stopped cannot acknowledge close, and it
                # has retired its own subscriptions. Finish closing rather than
                # stranding a client that could never be closed again.
                error isa ConvexError && error.kind == :closed || rethrow()
            end
        end
        status = timedwait(
            () -> istaskdone(manager.supervisor),
            CLOSE_TIMEOUT_SECONDS;
            pollint = 0.002,
        )
        status == :ok || throw(
            ConvexError(:transport, "timed out closing Live worker", nothing, String[]),
        )
        lock(client.lock) do
            client.closed = true
            client.closing = false
        end
        # Surface an owner that died from an unexpected error, but only once the
        # client is already marked closed so close! stays idempotent.
        istaskfailed(manager.supervisor) && wait(manager.supervisor)
    catch
        lock(client.lock) do
            client.closing = false
        end
        rethrow()
    end
    return nothing
end

function debug_disconnect_for_adapter(client::Client)
    manager = lock(client.lock) do
        isnothing(client.live) && throw(
            ConvexError(:transport, "Live WebSocket is not connected", nothing, String[]),
        )
        client.live
    end
    manager_command(manager, (:debug_disconnect,); timeout = CLOSE_TIMEOUT_SECONDS)
    return nothing
end

function manager_command(manager::LiveManager, command; timeout::Real)
    reply = Channel{Any}(1)
    deadline = time() + timeout
    envelope = OwnerCommand(command, reply, deadline)
    # Serialize producers around the capacity check and buffered put. The lock
    # is released between retries so the owner and other expiring callers can
    # progress without creating a task blocked forever in put!.
    while true
        enqueued = lock(manager.command_lock) do
            istaskdone(manager.supervisor) &&
                throw(ConvexError(:closed, "Live worker stopped", nothing, String[]))
            if Base.n_avail(manager.commands) < manager.commands.sz_max
                put!(manager.commands, envelope)
                return true
            end
            return false
        end
        enqueued && break
        if time() >= deadline
            cancel_command!(envelope)
            throw(
                ConvexError(
                    :transport,
                    "timed out queueing Live owner command",
                    nothing,
                    String[],
                ),
            )
        end
        sleep(0.002)
    end
    remaining = max(0.0, deadline - time())
    status = timedwait(
        () -> isready(reply) || istaskdone(manager.supervisor),
        remaining;
        pollint = 0.002,
    )
    if status != :ok
        if cancel_command!(envelope)
            throw(
                ConvexError(
                    :transport,
                    "timed out waiting for Live owner",
                    nothing,
                    String[],
                ),
            )
        end
        claimed_status = timedwait(
            () -> isready(reply) || istaskdone(manager.supervisor),
            OWNER_COMMAND_GRACE_SECONDS;
            pollint = 0.002,
        )
        if claimed_status != :ok
            fail_stop_owner!(manager)
            throw(
                ConvexError(
                    :transport,
                    "Live owner command exceeded its bounded grace period",
                    nothing,
                    String[],
                ),
            )
        end
    end
    isready(reply) || throw(ConvexError(:closed, "Live worker stopped", nothing, String[]))
    result = take!(reply)
    result isa Exception && throw(result)
    return result
end

function cancel_command!(command::OwnerCommand)
    return lock(command.lock) do
        command.claimed && return false
        command.cancelled = true
        return true
    end
end

function defer_command!(command::OwnerCommand)
    lock(command.lock) do
        command.claimed = false
    end
    return nothing
end

function fail_stop_owner!(manager::LiveManager)
    manager.closing = true
    worker = manager.worker
    if worker !== current_task() && !istaskdone(worker)
        schedule(
            worker,
            ConvexError(
                :transport,
                "Live owner command exceeded its bound",
                nothing,
                String[],
            );
            error = true,
        )
    end
    timedwait(() -> istaskdone(manager.supervisor), CLOSE_TIMEOUT_SECONDS; pollint = 0.002)
    return nothing
end

function claim_command!(command::OwnerCommand)
    return lock(command.lock) do
        if command.cancelled || command.completed || time() > command.deadline
            command.cancelled = true
            return false
        end
        command.claimed = true
        return true
    end
end

function respond_command!(command::OwnerCommand, result)
    accepted = lock(command.lock) do
        if command.cancelled || command.completed
            return false
        end
        command.completed = true
        return true
    end
    accepted && put!(command.reply, result)
    return accepted
end

function owner_command(command::OwnerCommand)
    return command
end

# Language-local tests may exercise owner handling without starting a worker.
function owner_command(command::Tuple)
    return OwnerCommand(command[1:(end-1)], command[end], Inf)
end

function LiveManager(url::String, version::String)
    websocket_url = replace(url, r"^https:" => "wss:", r"^http:" => "ws:") * "/api/sync"
    commands = Channel{Any}(128)
    manager = LiveManager(
        websocket_url,
        version,
        commands,
        ReentrantLock(),
        Dict{Int,Any}(),
        Dict{Int,Vector{UInt8}}(),
        Dict{Int,Tuple{Symbol,Vector{UInt8}}}(),
        Set{Int}(),
        QueueBudget(),
        0,
        0,
        0,
        zero_version(),
        0,
        "InitialConnect",
        nothing,
        UInt64(0),
        INITIAL_BACKOFF_SECONDS,
        0.0,
        false,
        false,
        nothing,
        current_task(),
        current_task(),
    )
    manager.supervisor = @async live_worker(manager)
    manager.worker = manager.supervisor
    return manager
end

# This task alone reads and writes WebSocket bytes, changes query-set versions,
# retires connections, and schedules reconnects. Public callers only enqueue
# commands, which makes every acknowledgement an owner-ordered barrier.
function live_worker(manager::LiveManager)
    manager.owner_task = current_task()
    try
        live_worker_loop!(manager)
    finally
        # A fail-stopped or unexpectedly broken owner must still retire its
        # subscriptions and reject queued commands, otherwise callers would
        # wait out their own deadlines on a worker that no longer exists.
        retire_worker!(manager)
    end
    return nothing
end

function live_worker_loop!(manager::LiveManager)
    while !manager.closing
        while isready(manager.commands)
            handle_disconnected_command!(manager, take!(manager.commands))
        end
        manager.closing && break
        if isempty(manager.subscriptions) || time() < manager.reconnect_at
            sleep(0.002)
            continue
        end

        outcome = :transport
        failure = nothing
        try
            if startswith(manager.websocket_url, "ws://")
                websocket = open_plain_websocket(manager)
                try
                    outcome = own_live_connection!(manager, websocket)
                finally
                    force_close!(websocket)
                end
            else
                HTTP.WebSockets.open(
                    manager.websocket_url;
                    headers = ["Convex-Client" => manager.client_version],
                    connect_timeout = HANDSHAKE_TIMEOUT_SECONDS,
                    # The owner polls OpenSSL directly. HTTP's read-timeout
                    # layer would add a detached task lasting the whole Live
                    # callback, rather than bounding only the Upgrade.
                    readtimeout = 0,
                    retry = false,
                    suppress_close_error = true,
                    maxframesize = MAX_LIVE_BYTES,
                ) do websocket
                    try
                        outcome = own_live_connection!(manager, websocket)
                    finally
                        force_close!(websocket)
                    end
                end
            end
        catch error
            failure = typed_error(error, :transport)
        finally
            manager.connected = false
            manager.worker = manager.supervisor
        end

        manager.closing && break
        if outcome == :debug || outcome == :no_subscriptions
            continue
        end
        if failure !== nothing
            fail_pending_subscriptions!(manager, failure)
            publish_all_error!(manager, failure)
            schedule_reconnect!(manager, sprint(showerror, failure))
        elseif !isempty(manager.subscriptions)
            transport = ConvexError(:transport, "Live connection ended", nothing, String[])
            publish_all_error!(manager, transport)
            schedule_reconnect!(manager, transport.message)
        end
    end
    return nothing
end

function retire_worker!(manager::LiveManager)
    for state in values(manager.subscriptions)
        if hasproperty(state, :pending_reply) && !isnothing(state.pending_reply)
            respond_command!(
                state.pending_reply,
                ConvexError(:closed, "Live worker stopped", nothing, String[]),
            )
        end
        finish_subscription!(state.subscription)
    end
    empty!(manager.subscriptions)
    # Reject anything that raced with shutdown so no completed manager retains
    # orphaned envelopes in its bounded mailbox.
    while isready(manager.commands)
        envelope = owner_command(take!(manager.commands))
        respond_command!(
            envelope,
            ConvexError(:closed, "Live worker stopped", nothing, String[]),
        )
    end
    return nothing
end

function own_live_connection!(manager::LiveManager, websocket)
    manager.owner_task = current_task()
    manager.worker = current_task()
    manager.connected = true
    manager.remote_version = zero_version()
    empty!(manager.remote_values)
    manager.pending_hydration = Set(keys(manager.subscriptions))
    manager.query_set_version = 0
    configure_write_timeout!(websocket)
    send_connect_and_hydrate!(manager, websocket)
    isempty(manager.subscriptions) && return :no_subscriptions
    manager.next_backoff = INITIAL_BACKOFF_SECONDS
    return connected_loop!(manager, websocket)
end

function open_plain_websocket(manager::LiveManager)
    uri = HTTP.URI(manager.websocket_url)
    port_text = string(uri.port)
    port = isempty(port_text) ? 80 : parse(Int, port_text)
    socket = connect(uri.host, port)
    try
        key = base64encode(rand(Random.RandomDevice(), UInt8, 16))
        path = isempty(uri.path) ? "/" : uri.path
        isempty(uri.query) || (path *= "?" * uri.query)
        host = occursin(':', uri.host) ? "[" * uri.host * "]" : uri.host
        port == 80 || (host *= ":" * string(port))
        request = join(
            [
                "GET $(path) HTTP/1.1",
                "Host: $(host)",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: $(key)",
                "Sec-WebSocket-Version: 13",
                "Convex-Client: $(manager.client_version)",
                "",
                "",
            ],
            "\r\n",
        )
        descriptor = socket_descriptor(socket)
        wait_write_ready!(descriptor, time() + HANDSHAKE_TIMEOUT_SECONDS)
        write(socket, request)
        flush(socket)

        response = UInt8[]
        deadline = time() + HANDSHAKE_TIMEOUT_SECONDS
        header_range = nothing
        while isnothing(header_range)
            time() < deadline || throw(
                ConvexError(
                    :transport,
                    "Live WebSocket handshake timed out",
                    nothing,
                    String[],
                ),
            )
            if poll_read_ready(descriptor)
                append!(
                    response,
                    recv_nonblocking(
                        descriptor,
                        NETWORK_READ_CHUNK,
                        "Live peer closed during WebSocket handshake",
                    ),
                )
                length(response) <= 64 * 1024 || throw(
                    ConvexError(
                        :protocol,
                        "WebSocket handshake headers exceed byte limit",
                        nothing,
                        String[],
                    ),
                )
                header_range = findfirst(Vector{UInt8}(codeunits("\r\n\r\n")), response)
            else
                sleep(0.002)
            end
        end
        header_end = last(header_range)
        validate_websocket_upgrade(String(response[1:header_end]), key)
        buffered =
            header_end < length(response) ? copy(response[(header_end+1):end]) : UInt8[]
        return RawWebSocket(RawConnection(socket), buffered, true, false, false)
    catch
        close(socket)
        rethrow()
    end
end

# The handshake and the connected owner share this bounded read. Each supplies
# its own end-of-stream message so a peer that disappears mid-session is never
# reported, or replayed as `lastCloseReason`, as a handshake failure.
function recv_nonblocking(descriptor::Cint, limit::Int, closed_message::String)
    bytes = Vector{UInt8}(undef, min(NETWORK_READ_CHUNK, limit))
    count = GC.@preserve bytes ccall(
        :recv,
        Cssize_t,
        (Cint, Ptr{UInt8}, Csize_t, Cint),
        descriptor,
        pointer(bytes),
        length(bytes),
        0x40,
    )
    count > 0 && return resize!(bytes, Int(count))
    count == 0 && throw(ConvexError(:transport, closed_message, nothing, String[]))
    error_code = Base.Libc.errno()
    error_code in (Base.Libc.EAGAIN, Base.Libc.EWOULDBLOCK) && return UInt8[]
    throw(
        ConvexError(
            :transport,
            "Live socket read failed with errno $(error_code)",
            nothing,
            String[],
        ),
    )
end

function validate_websocket_upgrade(header::String, key::String)
    lines = split(header, "\r\n")
    !isempty(lines) && startswith(lines[1], "HTTP/1.1 101") || throw(
        ConvexError(:transport, "WebSocket Upgrade did not return 101", nothing, String[]),
    )
    headers = Dict{String,String}()
    for line in lines[2:end]
        isempty(line) && continue
        separator = findfirst(':', line)
        isnothing(separator) && throw(
            ConvexError(:protocol, "malformed WebSocket Upgrade header", nothing, String[]),
        )
        headers[lowercase(strip(line[1:(separator-1)]))] = strip(line[(separator+1):end])
    end
    lowercase(get(headers, "upgrade", "")) == "websocket" || throw(
        ConvexError(:protocol, "WebSocket Upgrade header was missing", nothing, String[]),
    )
    "upgrade" in split(lowercase(get(headers, "connection", "")), r"\s*,\s*") || throw(
        ConvexError(
            :protocol,
            "WebSocket Connection header was missing",
            nothing,
            String[],
        ),
    )
    expected = base64encode(sha1(key * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    get(headers, "sec-websocket-accept", "") == expected ||
        throw(ConvexError(:protocol, "WebSocket accept key was invalid", nothing, String[]))
    return nothing
end

function fail_pending_subscriptions!(manager::LiveManager, error::ConvexError)
    for (id, state) in collect(manager.subscriptions)
        hasproperty(state, :pending_reply) && !isnothing(state.pending_reply) || continue
        respond_command!(state.pending_reply, error)
        remove_subscription!(manager, id, state.generation)
    end
    return nothing
end

function handle_disconnected_command!(manager::LiveManager, command)
    envelope = owner_command(command)
    claim_command!(envelope) || return nothing
    kind = envelope.parts[1]
    if kind === :subscribe
        _, path, args, request_bytes = envelope.parts
        if length(manager.subscriptions) >= MAX_SUBSCRIPTIONS ||
           manager.subscription_bytes + request_bytes > MAX_SUBSCRIPTION_BYTES
            respond_command!(
                envelope,
                ConvexError(
                    :protocol,
                    "Live subscription state budget exceeded",
                    nothing,
                    String[],
                ),
            )
            return nothing
        end
        id = manager.next_query_id
        manager.next_query_id += 1
        subscription = Subscription(manager, id, 1, QueuedUpdate[], manager.budget, false)
        # The caller's acknowledgement remains pending until Connect and the
        # containing Add have both been flushed by the socket owner.
        manager.subscriptions[id] = (
            path = path,
            args = args,
            subscription = subscription,
            generation = 1,
            pending_reply = envelope,
            request_bytes = request_bytes,
        )
        manager.subscription_bytes += request_bytes
        manager.reconnect_at = min(manager.reconnect_at, time())
        # No socket operation has begun. A handshake timeout may still cancel
        # this deferred Add before hydration claims it.
        defer_command!(envelope)
    elseif kind === :unsubscribe
        _, id, generation = envelope.parts
        remove_subscription!(manager, id, generation)
        respond_command!(envelope, nothing)
    elseif kind === :debug_disconnect
        respond_command!(
            envelope,
            ConvexError(:transport, "Live WebSocket is not connected", nothing, String[]),
        )
    elseif kind === :close
        manager.closing = true
        respond_command!(envelope, nothing)
    else
        respond_command!(
            envelope,
            ConvexError(:protocol, "unknown Live owner command", nothing, String[]),
        )
    end
    return nothing
end

function connected_loop!(manager::LiveManager, websocket)
    parser = FrameParser()
    transport_socket = HTTP.IOExtras.tcpsocket(websocket)
    descriptor = socket_descriptor(transport_socket)
    while !manager.closing
        if parser.tls_stall_deadline > 0 && time() >= parser.tls_stall_deadline
            throw(
                ConvexError(
                    :transport,
                    "TLS record made partial progress then stalled",
                    nothing,
                    String[],
                ),
            )
        end
        if parser.frame_stall_deadline > 0 && time() >= parser.frame_stall_deadline
            throw(
                ConvexError(
                    :transport,
                    "WebSocket frame made partial progress then stalled",
                    nothing,
                    String[],
                ),
            )
        end
        command_count = 0
        while isready(manager.commands) && command_count < 32
            command_count += 1
            envelope = owner_command(take!(manager.commands))
            claim_command!(envelope) || continue
            kind = envelope.parts[1]
            if kind === :subscribe
                _, path, args, request_bytes = envelope.parts
                if length(manager.subscriptions) >= MAX_SUBSCRIPTIONS ||
                   manager.subscription_bytes + request_bytes > MAX_SUBSCRIPTION_BYTES
                    respond_command!(
                        envelope,
                        ConvexError(
                            :protocol,
                            "Live subscription state budget exceeded",
                            nothing,
                            String[],
                        ),
                    )
                    continue
                end
                id = manager.next_query_id
                manager.next_query_id += 1
                subscription =
                    Subscription(manager, id, 1, QueuedUpdate[], manager.budget, false)
                state = (
                    path = path,
                    args = args,
                    subscription = subscription,
                    generation = 1,
                    pending_reply = nothing,
                    request_bytes = request_bytes,
                )
                manager.subscriptions[id] = state
                manager.subscription_bytes += request_bytes
                try
                    modify_query_set!(manager, websocket, [add_modification(id, state)])
                    if !respond_command!(envelope, subscription)
                        remove_subscription!(manager, id, 1)
                        modify_query_set!(
                            manager,
                            websocket,
                            [Dict{String,Any}("type" => "Remove", "queryId" => id)],
                        )
                    end
                catch error
                    remove_subscription!(manager, id, 1)
                    respond_command!(envelope, typed_error(error, :transport))
                    rethrow()
                end
            elseif kind === :unsubscribe
                _, id, generation = envelope.parts
                state = get(manager.subscriptions, id, nothing)
                if !isnothing(state) && state.generation == generation
                    # Invalidate the relay before Remove is written and before
                    # its acknowledgement becomes visible to the caller.
                    remove_subscription!(manager, id, generation)
                    modify_query_set!(
                        manager,
                        websocket,
                        [Dict{String,Any}("type" => "Remove", "queryId" => id)],
                    )
                end
                respond_command!(envelope, nothing)
                isempty(manager.subscriptions) && return :no_subscriptions
            elseif kind === :debug_disconnect
                # Retire the old transport and schedule reconnect work before
                # publishing the acknowledgement barrier.
                force_close!(websocket)
                schedule_reconnect!(manager, "DebugDisconnect"; delay = 0.0)
                respond_command!(envelope, nothing)
                return :debug
            elseif kind === :close
                manager.closing = true
                force_close!(websocket)
                respond_command!(envelope, nothing)
                return :close
            else
                respond_command!(
                    envelope,
                    ConvexError(:protocol, "unknown Live owner command", nothing, String[]),
                )
            end
        end

        # Drain already-buffered complete frames before pulling another 64 KiB
        # from the peer. A control-frame flood cannot grow parser memory merely
        # because processing is deliberately capped for command fairness.
        # One frame per turn preserves wire order when a terminal control frame
        # follows a text update in the same kernel read. Commands still get a
        # fairness point between every frame.
        messages, frames_processed =
            parse_frames!(parser, manager, websocket; frame_limit = 1)
        for payload in messages
            message = decode_live_message(payload)
            handle_server_message!(manager, message)
            manager.next_backoff = INITIAL_BACKOFF_SECONDS
        end
        frames_processed > 0 && continue

        chunk = read_ready_websocket_bytes(websocket, transport_socket, descriptor, parser)
        if !isempty(chunk)
            append!(parser.bytes, chunk)
            parser.frame_stall_deadline == 0.0 &&
                (parser.frame_stall_deadline = time() + FRAME_STALL_TIMEOUT_SECONDS)
            length(parser.bytes) + length(parser.fragmented_payload) <=
            MAX_LIVE_BYTES + 14 || throw(
                ConvexError(:protocol, "Live frame exceeds byte limit", nothing, String[]),
            )
        end
        if isempty(chunk) && !isopen(websocket.io)
            throw(
                ConvexError(
                    :transport,
                    "Live peer closed the connection",
                    nothing,
                    String[],
                ),
            )
        elseif isempty(chunk)
            sleep(0.002)
        end
    end
    return :close
end

# One maximal frame, its header, and any retained fragmented payload share the
# same bounded buffer. Reading only up to the remaining budget lets a peer
# pipeline the next frame behind a near-maximum one without ever growing the
# parser past its documented limit or rejecting a conforming stream.
function read_budget(parser::FrameParser)
    remaining =
        MAX_LIVE_BYTES + 14 - length(parser.bytes) - length(parser.fragmented_payload)
    remaining > 0 ||
        throw(ConvexError(:protocol, "Live frame exceeds byte limit", nothing, String[]))
    return min(NETWORK_READ_CHUNK, remaining)
end

function read_ready_websocket_bytes(
    websocket,
    transport_socket,
    descriptor::Cint,
    parser::FrameParser,
)
    limit = read_budget(parser)
    if websocket isa RawWebSocket
        if !isempty(websocket.buffer)
            count = min(length(websocket.buffer), limit)
            bytes = copy(websocket.buffer[1:count])
            deleteat!(websocket.buffer, 1:count)
            return bytes
        end
        poll_read_ready(descriptor) || return UInt8[]
        return recv_nonblocking(descriptor, limit, "Live peer closed the connection")
    end
    connection = websocket.io
    if bytesavailable(connection.buffer) > 0
        return read(connection.buffer, min(bytesavailable(connection.buffer), limit))
    end
    transport = connection.io
    buffered = bytesavailable(transport)
    libuv_buffered = bytesavailable(transport_socket)
    kernel_buffered = kernel_bytes_available(descriptor)
    raw_buffered = max(libuv_buffered, kernel_buffered)
    descriptor_ready = poll_read_ready(descriptor)
    descriptor_ready &&
        kernel_buffered == 0 &&
        socket_peer_eof(descriptor) &&
        throw(ConvexError(:transport, "Live peer closed the connection", nothing, String[]))
    ready =
        buffered > 0 ||
        raw_buffered > 0 ||
        descriptor_ready ||
        parser.tls_wants_write ||
        parser.tls_retry_read
    if transport isa OpenSSL.SSLStream
        if transport.io.status == Base.StatusEOF || !isopen(transport.io)
            throw(
                ConvexError(
                    :transport,
                    "TLS peer closed the connection",
                    nothing,
                    String[],
                ),
            )
        end
        ready || return UInt8[]
        # OpenSSL.jl's BIO callback only drains Julia's libuv buffer. A kernel
        # readiness probe does not itself move bytes there, so start libuv only
        # after the fd proves readable and return to the owner loop. The libuv
        # callback fills the BIO's source buffer without ever blocking command
        # processing on a byte that a racy readiness result did not deliver.
        if bytesavailable(transport.io) == 0 && (raw_buffered > 0 || descriptor_ready)
            Base.start_reading(transport.io)
            return UInt8[]
        end
        raw_before_read = bytesavailable(transport.io)
        bytes, status, application_pending = read_tls_once(transport, limit)
        parser.tls_wants_write = status == :want_write
        # OpenSSL may still hold decrypted bytes when the bounded read stopped
        # short of a whole record. Retry regardless of status, or that record
        # would wait for unrelated inbound traffic to make the socket readable.
        parser.tls_retry_read = application_pending
        if status == :ok
            parser.tls_stall_deadline = 0.0
        elseif parser.tls_stall_deadline == 0.0 &&
               (raw_before_read > 0 || status == :want_write)
            # The first consumed byte starts one absolute record deadline.
            # Further trickle bytes cannot extend it indefinitely.
            parser.tls_stall_deadline = time() + TLS_RECORD_TIMEOUT_SECONDS
        end
        return bytes
    end
    ready || return UInt8[]
    if transport isa TCPSocket
        first = read(transport, UInt8)
        remaining = min(bytesavailable(transport), limit - 1)
        rest = remaining > 0 ? read(transport, remaining) : UInt8[]
        return vcat(UInt8[first], rest)
    elseif buffered == 0
        # Read through the HTTP transport, never from the raw fd. For TLS this
        # decrypts ready ciphertext; SO_RCVTIMEO abandons a partial TLS record.
        first = read(transport, UInt8)
        remaining = min(bytesavailable(transport), limit - 1)
        rest = remaining > 0 ? read(transport, remaining) : UInt8[]
        chunk = vcat(UInt8[first], rest)
    else
        chunk = read(transport, min(buffered, limit))
    end
    length(chunk) <= NETWORK_READ_CHUNK || throw(
        ConvexError(
            :protocol,
            "Live peer exceeded the bounded receive window",
            nothing,
            String[],
        ),
    )
    return chunk
end

# OpenSSL.jl's ordinary unsafe_read loops on WANT_READ and blocks in eof(raw
# socket). One SSL_read_ex attempt lets the sole WebSocket owner preserve the
# library's TLS parser state, return to its command mailbox, and retry only when
# the raw socket or OpenSSL pending buffer reports progress.
function read_tls_once(transport::OpenSSL.SSLStream, limit::Int)
    buffer = Vector{UInt8}(undef, min(NETWORK_READ_CHUNK, limit))
    error_code, application_pending = lock(transport.lock) do
        transport.closed &&
            throw(ConvexError(:transport, "TLS stream is closed", nothing, String[]))
        transport.readbytes[] = 0
        OpenSSL.clear_errors!()
        raw = GC.@preserve buffer ccall(
            (:SSL_read_ex, OpenSSL.OpenSSL_jll.libssl),
            Cint,
            (OpenSSL.SSL, Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
            transport.ssl,
            pointer(buffer),
            length(buffer),
            transport.readbytes,
        )
        code = raw == 1 ? OpenSSL.SSL_ERROR_NONE : OpenSSL.get_error(transport.ssl, raw)
        if code == OpenSSL.SSL_ERROR_NONE
            resize!(buffer, Int(transport.readbytes[]))
        end
        pending_application_bytes =
            ccall(
                (:SSL_pending, OpenSSL.OpenSSL_jll.libssl),
                Cint,
                (OpenSSL.SSL,),
                transport.ssl,
            ) > 0
        (code, pending_application_bytes)
    end
    error_code == OpenSSL.SSL_ERROR_NONE && return buffer, :ok, application_pending
    error_code == OpenSSL.SSL_ERROR_WANT_READ &&
        return UInt8[], :want_read, application_pending
    error_code == OpenSSL.SSL_ERROR_WANT_WRITE &&
        return UInt8[], :want_write, application_pending
    error_code == OpenSSL.SSL_ERROR_ZERO_RETURN &&
        throw(ConvexError(:transport, "TLS peer closed the connection", nothing, String[]))
    throw(
        ConvexError(
            :transport,
            "OpenSSL read failed with $(error_code)",
            nothing,
            String[],
        ),
    )
end

function kernel_bytes_available(descriptor::Cint)
    count = Ref{Cint}(0)
    result = ccall(:ioctl, Cint, (Cint, Culong, Ptr{Cint}), descriptor, 0x541b, count)
    result == 0 || return 0
    return Int(count[])
end

function poll_read_ready(descriptor::Cint)
    poll_descriptor = Ref(PollDescriptor(descriptor, Cshort(0x001), Cshort(0)))
    result = ccall(:poll, Cint, (Ptr{PollDescriptor}, Culong, Cint), poll_descriptor, 1, 0)
    result > 0 || return false
    return (poll_descriptor[].returned_events & Cshort(0x019)) != 0
end

function socket_peer_eof(descriptor::Cint)
    byte = Ref{UInt8}(0)
    result = ccall(
        :recv,
        Cssize_t,
        (Cint, Ptr{UInt8}, Csize_t, Cint),
        descriptor,
        byte,
        1,
        # MSG_PEEK preserves transport bytes; MSG_DONTWAIT makes a racy
        # readiness result harmless instead of blocking the sole owner.
        0x02 | 0x40,
    )
    return result == 0
end

function send_connect_and_hydrate!(manager::LiveManager, websocket)
    connect = Dict{String,Any}(
        "type" => "Connect",
        "sessionId" => string(uuid4()),
        "connectionCount" => manager.connection_count,
        "lastCloseReason" => manager.last_close_reason,
        "clientTs" => round(Int, time() * 1000),
    )
    isnothing(manager.max_observed_timestamp) ||
        (connect["maxObservedTimestamp"] = manager.max_observed_timestamp)
    send_json!(manager, websocket, connect)
    # A disconnected subscribe may expire while the handshake is in flight.
    # Purge it before constructing Add records so a timed-out command can never
    # execute later merely because the transport eventually became healthy.
    for (id, state) in collect(manager.subscriptions)
        if hasproperty(state, :pending_reply) && !isnothing(state.pending_reply)
            claim_command!(state.pending_reply) ||
                remove_subscription!(manager, id, state.generation)
        end
    end
    modifications = [
        add_modification(id, state) for
        (id, state) in sort(collect(manager.subscriptions); by = first)
    ]
    isempty(modifications) || modify_query_set!(manager, websocket, modifications)
    # ModifyQuerySet has been flushed at this point. Publishing the pending
    # subscription replies now makes subscribe() a real transport barrier.
    cancelled_ids = Int[]
    for (id, state) in collect(manager.subscriptions)
        if hasproperty(state, :pending_reply) && !isnothing(state.pending_reply)
            manager.subscriptions[id] = merge(state, (pending_reply = nothing,))
            respond_command!(state.pending_reply, state.subscription) ||
                push!(cancelled_ids, id)
        end
    end
    if !isempty(cancelled_ids)
        for id in cancelled_ids
            state = get(manager.subscriptions, id, nothing)
            isnothing(state) || remove_subscription!(manager, id, state.generation)
        end
        modify_query_set!(
            manager,
            websocket,
            [Dict{String,Any}("type" => "Remove", "queryId" => id) for id in cancelled_ids],
        )
    end
    return nothing
end

function send_json!(manager::LiveManager, websocket, message)
    current_task() === manager.owner_task || throw(
        ConvexError(:protocol, "WebSocket write escaped its owner", nothing, String[]),
    )
    encoded = JSON3.write(message)
    ncodeunits(encoded) <= MAX_LIVE_BYTES ||
        throw(ConvexError(:protocol, "Live write exceeds byte limit", nothing, String[]))
    timed_owner_write!(manager, websocket) do
        write_text_frames!(websocket, encoded)
        flush(websocket.io)
    end
    return nothing
end

function write_text_frames!(websocket, text::String)
    bytes = Vector{UInt8}(codeunits(text))
    descriptor = socket_descriptor(HTTP.IOExtras.tcpsocket(websocket))
    deadline = time() + WRITE_TIMEOUT_SECONDS
    if isempty(bytes)
        wait_write_ready!(descriptor, deadline)
        frame = HTTP.WebSockets.Frame(true, HTTP.WebSockets.TEXT, websocket.client, UInt8[])
        HTTP.WebSockets.writeframe(websocket.io, frame)
        return nothing
    end
    cursor = 1
    first = true
    while cursor <= length(bytes)
        finish = min(cursor + NETWORK_WRITE_CHUNK - 1, length(bytes))
        final = finish == length(bytes)
        payload = copy(@view bytes[cursor:finish])
        opcode = first ? HTTP.WebSockets.TEXT : HTTP.WebSockets.CONTINUATION
        wait_write_ready!(descriptor, deadline)
        frame = HTTP.WebSockets.Frame(final, opcode, websocket.client, payload)
        HTTP.WebSockets.writeframe(websocket.io, frame)
        first = false
        cursor = finish + 1
    end
    return nothing
end

function write_pong_frame!(websocket, payload::Vector{UInt8})
    descriptor = socket_descriptor(HTTP.IOExtras.tcpsocket(websocket))
    wait_write_ready!(descriptor, time() + WRITE_TIMEOUT_SECONDS)
    frame =
        HTTP.WebSockets.Frame(true, HTTP.WebSockets.PONG, websocket.client, copy(payload))
    HTTP.WebSockets.writeframe(websocket.io, frame)
    return nothing
end

function wait_write_ready!(descriptor::Cint, deadline::Float64)
    while true
        remaining_ms = max(0, ceil(Int, (deadline - time()) * 1000))
        remaining_ms > 0 ||
            throw(ConvexError(:transport, "Live write timed out", nothing, String[]))
        poll_descriptor = Ref(PollDescriptor(descriptor, Cshort(0x004), Cshort(0)))
        result = ccall(
            :poll,
            Cint,
            (Ptr{PollDescriptor}, Culong, Cint),
            poll_descriptor,
            1,
            remaining_ms,
        )
        result > 0 && return nothing
        result == 0 &&
            throw(ConvexError(:transport, "Live write timed out", nothing, String[]))
        Base.Libc.errno() == 4 || throw(SystemError("poll WebSocket write", true))
    end
end

function timed_owner_write!(action::Function, manager::LiveManager, websocket)
    current_task() === manager.owner_task || throw(
        ConvexError(:protocol, "WebSocket write escaped its owner", nothing, String[]),
    )
    try
        action()
    catch error
        throw(typed_error(error, :transport))
    end
    return nothing
end

function modify_query_set!(manager::LiveManager, websocket, modifications)
    message = Dict{String,Any}(
        "type" => "ModifyQuerySet",
        "baseVersion" => manager.query_set_version,
        "newVersion" => manager.query_set_version + 1,
        "modifications" => collect(Any, modifications),
    )
    send_json!(manager, websocket, message)
    manager.query_set_version += 1
    return nothing
end

add_modification(id, state) = Dict{String,Any}(
    "type" => "Add",
    "queryId" => id,
    "udfPath" => state.path,
    "args" => Any[state.args],
)

function schedule_reconnect!(
    manager::LiveManager,
    reason::String;
    delay = manager.next_backoff,
)
    manager.last_close_reason = bounded_utf8(reason, MAX_CLOSE_REASON_BYTES)
    manager.connection_count += 1
    manager.reconnect_at = time() + delay
    if delay > 0
        manager.next_backoff = min(manager.next_backoff * 2, MAX_BACKOFF_SECONDS)
    end
    manager.query_set_version = 0
    manager.remote_version = zero_version()
    empty!(manager.remote_values)
    empty!(manager.pending_hydration)
    return nothing
end

function bounded_utf8(value::String, limit::Int)
    ncodeunits(value) <= limit && return value
    bytes = Vector{UInt8}(codeunits(value))[1:limit]
    while !isempty(bytes) && !isvalid(String(copy(bytes)))
        pop!(bytes)
    end
    return String(bytes)
end

function remove_subscription!(manager::LiveManager, id::Int, generation::Int)
    state = get(manager.subscriptions, id, nothing)
    if !isnothing(state) && state.generation == generation
        delete!(manager.subscriptions, id)
        delete!(manager.remote_values, id)
        delete!(manager.last_delivered, id)
        delete!(manager.pending_hydration, id)
        manager.subscription_bytes -=
            hasproperty(state, :request_bytes) ? state.request_bytes : 0
        finish_subscription!(state.subscription)
    end
    return nothing
end

function handle_server_message!(manager::LiveManager, message)
    message_type = jsonget(message, "type", nothing)
    message_type isa AbstractString ||
        throw(ConvexError(:protocol, "Live message omitted string type", nothing, String[]))
    if message_type == "Transition"
        apply_transition!(manager, message)
    elseif message_type in ("Ping", "MutationResponse", "ActionResponse")
        return nothing
    elseif message_type == "TransitionChunk"
        throw(
            ConvexError(
                :protocol,
                "TransitionChunk assembly is not implemented",
                nothing,
                String[],
            ),
        )
    elseif message_type in ("FatalError", "AuthError")
        detail = jsonget(message, "error", message_type)
        throw(ConvexError(:protocol, "$(message_type): $(detail)", nothing, String[]))
    else
        throw(
            ConvexError(
                :protocol,
                "unsupported Live message $(repr(message_type))",
                nothing,
                String[],
            ),
        )
    end
    return nothing
end

function apply_transition!(manager::LiveManager, message)
    start_version =
        decode_version(jsonget(message, "startVersion", nothing), "startVersion")
    end_version = decode_version(jsonget(message, "endVersion", nothing), "endVersion")
    start_version == manager.remote_version || throw(
        ConvexError(
            :protocol,
            "Transition startVersion does not match local state",
            nothing,
            String[],
        ),
    )
    start_version.query_set <= end_version.query_set <= manager.query_set_version || throw(
        ConvexError(
            :protocol,
            "Transition querySet is outside the sent query-set range",
            nothing,
            String[],
        ),
    )
    end_version.timestamp >= start_version.timestamp || throw(
        ConvexError(:protocol, "Transition timestamp moved backwards", nothing, String[]),
    )

    modifications = jsonget(message, "modifications", nothing)
    modifications isa AbstractVector || throw(
        ConvexError(
            :protocol,
            "Transition modifications must be an array",
            nothing,
            String[],
        ),
    )

    # Validate and coalesce into temporary maps first. A malformed late entry
    # cannot partially commit timestamps, values, logs, or subscriber events.
    next_values = copy(manager.remote_values)
    changed = Dict{Int,LiveUpdate}()
    for modification in modifications
        modification isa AbstractDict || throw(
            ConvexError(
                :protocol,
                "Transition modification must be an object",
                nothing,
                String[],
            ),
        )
        modification_type = jsonget(modification, "type", nothing)
        modification_type isa AbstractString || throw(
            ConvexError(
                :protocol,
                "Transition modification omitted string type",
                nothing,
                String[],
            ),
        )
        id = wire_int(jsonget(modification, "queryId", nothing), "queryId")
        logs = validated_logs(jsonget(modification, "logLines", Any[]))
        if modification_type == "QueryUpdated"
            jsonhas(modification, "value") ||
                throw(ConvexError(:protocol, "QueryUpdated omitted value", nothing, logs))
            value = jsonget(modification, "value", nothing)
            encoded = JSON3.write(value)
            ncodeunits(encoded) <= MAX_LIVE_BYTES || throw(
                ConvexError(:protocol, "Live value exceeds byte limit", nothing, logs),
            )
            if haskey(manager.subscriptions, id)
                next_values[id] = sha256(encoded)
                changed[id] = LiveUpdate(public_value(value), nothing, logs)
            end
        elseif modification_type == "QueryFailed"
            message_value = jsonget(modification, "errorMessage", "Live query failed")
            message_value isa AbstractString || throw(
                ConvexError(
                    :protocol,
                    "QueryFailed errorMessage must be a string",
                    nothing,
                    logs,
                ),
            )
            error = ConvexError(
                :function_error,
                String(message_value),
                public_value(jsonget(modification, "errorData", nothing)),
                logs,
            )
            if haskey(manager.subscriptions, id)
                next_values[id] = sha256(
                    JSON3.write(Dict("message" => error.message, "data" => error.data)),
                )
                changed[id] = LiveUpdate(nothing, error, logs)
            end
        elseif modification_type == "QueryRemoved"
            delete!(next_values, id)
            delete!(changed, id)
        else
            throw(
                ConvexError(
                    :protocol,
                    "unknown Transition modification $(repr(modification_type))",
                    nothing,
                    logs,
                ),
            )
        end
    end

    manager.remote_values = next_values
    manager.remote_version = end_version
    if end_version.timestamp > manager.max_observed_timestamp_value
        manager.max_observed_timestamp_value = end_version.timestamp
        manager.max_observed_timestamp = end_version.encoded_timestamp
    end

    for id in sort!(collect(keys(changed)))
        state = get(manager.subscriptions, id, nothing)
        isnothing(state) && continue
        update = changed[id]
        signature = update_signature(update)
        hydration = id in manager.pending_hydration
        delete!(manager.pending_hydration, id)
        # Only the first result for a re-sent Add is reconnect hydration. A
        # later same-value update or repeated error is still observable,
        # including its new log lines.
        if hydration && get(manager.last_delivered, id, nothing) == signature
            continue
        end
        manager.last_delivered[id] = signature
        deliver!(state.subscription, update)
    end
    return nothing
end

function decode_version(@nospecialize(value), label::String)
    value isa AbstractDict ||
        throw(ConvexError(:protocol, "$(label) must be an object", nothing, String[]))
    query_set = wire_int(jsonget(value, "querySet", nothing), "$(label).querySet")
    identity = wire_int(jsonget(value, "identity", nothing), "$(label).identity")
    encoded = jsonget(value, "ts", nothing)
    encoded isa AbstractString ||
        throw(ConvexError(:protocol, "$(label).ts must be a string", nothing, String[]))
    return (
        query_set = query_set,
        identity = identity,
        timestamp = timestamp_value(encoded),
        encoded_timestamp = String(encoded),
    )
end

function deliver!(subscription::Subscription, update::LiveUpdate)
    encoded_bytes = ncodeunits(
        JSON3.write(
            Dict(
                "value" => update.value,
                "error" =>
                    isnothing(update.error) ? nothing :
                    Dict("message" => update.error.message, "data" => update.error.data),
                "logs" => update.logs,
            ),
        ),
    )
    encoded_bytes <= MAX_LIVE_BYTES || return nothing
    budget = subscription.budget
    lock(budget.lock) do
        subscription.finished && return
        queued = QueuedUpdate(subscription, update, encoded_bytes)
        while !isempty(budget.order) && (
            length(budget.order) >= MAX_QUEUE_ITEMS ||
            budget.encoded_bytes + encoded_bytes > MAX_QUEUE_BYTES
        )
            oldest = popfirst!(budget.order)
            index = findfirst(item -> item === oldest, oldest.owner.queue)
            isnothing(index) || deleteat!(oldest.owner.queue, index)
            budget.encoded_bytes -= oldest.encoded_bytes
        end
        push!(subscription.queue, queued)
        push!(budget.order, queued)
        budget.encoded_bytes += encoded_bytes
    end
    return nothing
end

function finish_subscription!(subscription::Subscription)
    budget = subscription.budget
    lock(budget.lock) do
        subscription.finished = true
        for queued in subscription.queue
            index = findfirst(item -> item === queued, budget.order)
            isnothing(index) || deleteat!(budget.order, index)
            budget.encoded_bytes -= queued.encoded_bytes
        end
        empty!(subscription.queue)
    end
    return nothing
end

function publish_all_error!(manager::LiveManager, error::ConvexError)
    for state in values(manager.subscriptions)
        update = LiveUpdate(nothing, error, error.logs)
        manager.last_delivered[state.subscription.query_id] = update_signature(update)
        deliver!(state.subscription, update)
    end
    return nothing
end

function update_signature(update::LiveUpdate)
    if isnothing(update.error)
        return (
            :value,
            sha256(JSON3.write(Dict("value" => update.value, "logs" => update.logs))),
        )
    end
    return (
        :error,
        sha256(
            JSON3.write(
                Dict(
                    "message" => update.error.message,
                    "data" => update.error.data,
                    "logs" => update.logs,
                ),
            ),
        ),
    )
end

function decode_live_message(payload::Vector{UInt8})
    length(payload) <= MAX_LIVE_BYTES ||
        throw(ConvexError(:protocol, "Live message exceeds byte limit", nothing, String[]))
    text = String(copy(payload))
    isvalid(text) || throw(
        ConvexError(:protocol, "Live text frame was not valid UTF-8", nothing, String[]),
    )
    try
        decoded = JSON3.read(text, Any)
        decoded isa AbstractDict || throw(
            ConvexError(:protocol, "Live message must be a JSON object", nothing, String[]),
        )
        return decoded
    catch error
        error isa ConvexError && rethrow()
        throw(
            ConvexError(
                :protocol,
                "Live message was not JSON: " * sprint(showerror, error),
                nothing,
                String[],
            ),
        )
    end
end

# Incrementally parse server frames so timeouts and partial reads never restart
# at a guessed boundary. Control frames may interleave fragmented UTF-8 text.
function parse_frames!(
    parser::FrameParser,
    manager::LiveManager,
    websocket;
    frame_limit::Int,
)
    messages = Vector{Vector{UInt8}}()
    frames = 0
    while frames < frame_limit
        length(parser.bytes) >= 2 || break
        first = parser.bytes[1]
        second = parser.bytes[2]
        final = (first & 0x80) != 0
        (first & 0x70) == 0 || throw(
            ConvexError(:protocol, "WebSocket reserved bits are set", nothing, String[]),
        )
        opcode = first & 0x0f
        masked = (second & 0x80) != 0
        masked && throw(
            ConvexError(
                :protocol,
                "server WebSocket frame must not be masked",
                nothing,
                String[],
            ),
        )
        length_code = Int(second & 0x7f)
        header_bytes = 2
        payload_bytes = UInt64(length_code)
        if length_code == 126
            length(parser.bytes) >= 4 || break
            payload_bytes = UInt64(parser.bytes[3]) << 8 | UInt64(parser.bytes[4])
            payload_bytes >= 126 || throw(
                ConvexError(:protocol, "non-canonical WebSocket length", nothing, String[]),
            )
            header_bytes = 4
        elseif length_code == 127
            length(parser.bytes) >= 10 || break
            (parser.bytes[3] & 0x80) == 0 || throw(
                ConvexError(
                    :protocol,
                    "invalid WebSocket 64-bit length",
                    nothing,
                    String[],
                ),
            )
            payload_bytes = UInt64(0)
            for byte in parser.bytes[3:10]
                payload_bytes = payload_bytes << 8 | UInt64(byte)
            end
            payload_bytes > 0xffff || throw(
                ConvexError(:protocol, "non-canonical WebSocket length", nothing, String[]),
            )
            header_bytes = 10
        end
        payload_bytes <= UInt64(MAX_LIVE_BYTES) || throw(
            ConvexError(:protocol, "WebSocket frame exceeds byte limit", nothing, String[]),
        )
        needed = header_bytes + Int(payload_bytes)
        length(parser.bytes) >= needed || break
        payload = copy(parser.bytes[(header_bytes+1):needed])
        deleteat!(parser.bytes, 1:needed)
        # A completed frame is real frame-level progress. Restart the deadline
        # for whatever remains buffered so a peer that keeps delivering whole
        # frames faster than they are drained is never mistaken for one that
        # stalled halfway through a frame.
        parser.frame_stall_deadline =
            isempty(parser.bytes) ? 0.0 : time() + FRAME_STALL_TIMEOUT_SECONDS
        frames += 1

        control = opcode >= 0x08
        control &&
            (!final || payload_bytes > 125) &&
            throw(
                ConvexError(
                    :protocol,
                    "invalid fragmented or oversized WebSocket control frame",
                    nothing,
                    String[],
                ),
            )
        if opcode == 0x08
            length(payload) == 1 && throw(
                ConvexError(
                    :protocol,
                    "invalid WebSocket close payload",
                    nothing,
                    String[],
                ),
            )
            if length(payload) >= 2
                reason = String(copy(payload[3:end]))
                isvalid(reason) || throw(
                    ConvexError(
                        :protocol,
                        "WebSocket close reason was not UTF-8",
                        nothing,
                        String[],
                    ),
                )
            end
            throw(
                ConvexError(:transport, "Live peer sent a close frame", nothing, String[]),
            )
        elseif opcode == 0x09
            timed_owner_write!(manager, websocket) do
                write_pong_frame!(websocket, payload)
                flush(websocket.io)
            end
        elseif opcode == 0x0a
            nothing
        elseif opcode == 0x01
            parser.fragmented_opcode == 0x00 || throw(
                ConvexError(
                    :protocol,
                    "new data frame interrupted a fragmented message",
                    nothing,
                    String[],
                ),
            )
            if final
                push!(messages, payload)
            else
                parser.fragmented_opcode = opcode
                parser.fragmented_payload = payload
            end
        elseif opcode == 0x00
            parser.fragmented_opcode == 0x01 || throw(
                ConvexError(
                    :protocol,
                    "unexpected WebSocket continuation frame",
                    nothing,
                    String[],
                ),
            )
            length(parser.fragmented_payload) + length(payload) <= MAX_LIVE_BYTES || throw(
                ConvexError(
                    :protocol,
                    "fragmented Live message exceeds byte limit",
                    nothing,
                    String[],
                ),
            )
            append!(parser.fragmented_payload, payload)
            if final
                push!(messages, parser.fragmented_payload)
                parser.fragmented_payload = UInt8[]
                parser.fragmented_opcode = 0x00
            end
        elseif opcode == 0x02
            throw(
                ConvexError(
                    :protocol,
                    "binary Live messages are unsupported",
                    nothing,
                    String[],
                ),
            )
        else
            throw(ConvexError(:protocol, "unknown WebSocket opcode", nothing, String[]))
        end
    end
    return messages, frames
end

function configure_write_timeout!(websocket)
    Sys.islinux() || return nothing
    socket = HTTP.IOExtras.tcpsocket(websocket)
    descriptor = socket_descriptor(socket)
    timeout = Ref{NTuple{2,Clong}}((Clong(WRITE_TIMEOUT_SECONDS), Clong(0)))
    for (option, operation) in ((21, "writes"), (20, "reads"))
        result = ccall(
            :setsockopt,
            Cint,
            (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
            descriptor,
            1,
            option,
            timeout,
            sizeof(timeout[]),
        )
        result == 0 || throw(
            ConvexError(
                :transport,
                "could not bound WebSocket $(operation)",
                nothing,
                String[],
            ),
        )
    end
    # Keep the kernel queue small enough that a peer which stops reading cannot
    # absorb a maximum-size Add and make the write deadline a paper guarantee.
    send_buffer = Ref{Cint}(4096)
    ccall(
        :setsockopt,
        Cint,
        (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
        descriptor,
        1,
        7,
        send_buffer,
        sizeof(send_buffer[]),
    ) == 0 || throw(
        ConvexError(:transport, "could not bound WebSocket send buffer", nothing, String[]),
    )
    # Linux aborts a connection whose acknowledged progress remains stalled
    # beyond this deadline. This bounds a blocked libuv write without moving
    # socket ownership to a timer or helper task.
    user_timeout_ms = Ref{Cuint}(round(Cuint, WRITE_TIMEOUT_SECONDS * 1000))
    ccall(
        :setsockopt,
        Cint,
        (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
        descriptor,
        6,
        18,
        user_timeout_ms,
        sizeof(user_timeout_ms[]),
    ) == 0 ||
        throw(ConvexError(:transport, "could not set TCP user timeout", nothing, String[]))
    return nothing
end

function socket_descriptor(socket)
    descriptor = Ref{Cint}(-1)
    ccall(:uv_fileno, Cint, (Ptr{Cvoid}, Ptr{Cint}), socket.handle, descriptor) == 0 ||
        throw(
            ConvexError(
                :transport,
                "could not inspect WebSocket descriptor",
                nothing,
                String[],
            ),
        )
    return descriptor[]
end

function force_close!(websocket)
    websocket.readclosed = true
    websocket.writeclosed = true
    try
        close(websocket.io)
    catch
    end
    return nothing
end

function typed_error(@nospecialize(error), kind::Symbol)
    error isa ConvexError && return error
    if hasproperty(error, :error)
        nested = getproperty(error, :error)
        nested isa ConvexError && return nested
    end
    # PackageCompiler's stripped image may first see a concrete HTTP.jl or
    # OpenSSL exception only on the hosted WSS path. Rendering that unknown
    # exception can itself require a missing showerror specialization, which
    # used to terminate the sole Live owner and leave callers with only
    # "Live worker stopped". Keep the transport failure structured and
    # deterministic even when the original exception was not retained.
    return ConvexError(kind, "Live transport failure", nothing, String[])
end
jsonhas(object, key) = haskey(object, Symbol(key)) || haskey(object, key)
jsonget(object, key, default) =
    haskey(object, Symbol(key)) ? object[Symbol(key)] :
    (haskey(object, key) ? object[key] : default)

# Adapter NDJSON, JSON3.Object values, and hand-written Dict{String,String}
# literals all enter here and leave as one concrete tree. That keeps the
# stripped AOT image from needing a separate Subscribe specialization per
# caller-shaped dictionary.
function canonicalize_args(args::AbstractDict)
    canonical = canonicalize_json_value(args)
    canonical isa Dict{String,Any} || throw(
        ConvexError(:protocol, "function args must be a JSON object", nothing, String[]),
    )
    return canonical
end

# These boundary helpers all receive a value whose type is only known at run
# time. `@nospecialize` keeps each of them to a single compiled instance, so an
# image with runtime compilation disabled can dispatch to them for any payload
# shape instead of needing one specialization per type a deployment sends.
#
# Every value this client hands back is a plain Julia tree, never a JSON3 view
# into a transport buffer. That keeps a queued Live update from pinning the
# whole response it arrived in, and it keeps the type surface finite. JSON3's
# lazy views are parameterised by the element types a payload happens to
# contain, so `[true, false]` and `[1, 2]` are different concrete types. An AOT
# image with runtime compilation disabled needs compiled code for every one of
# them, and dies on the first shape nobody predicted; decoding straight into
# plain containers keeps that set closed.
#
# Decoding already produced plain containers, so normalize them in place. Deep
# copying here would mean holding a second near-maximum tree while the response
# bytes, the JSON text, and the encoded event are all still alive, which is more
# than the container's memory limit leaves room for.
function public_value(@nospecialize(value))
    if value isa Dict{String,Any}
        for (key, item) in value
            normalized = public_value(item)
            normalized === item || (value[key] = normalized)
        end
        return value
    elseif value isa Vector{Any}
        for index in eachindex(value)
            item = value[index]
            normalized = public_value(item)
            normalized === item || (value[index] = normalized)
        end
        return value
    end
    return canonicalize_json_value(value)
end

function canonicalize_json_value(@nospecialize(value))
    if value isa AbstractDict
        object = Dict{String,Any}()
        for (key, item) in pairs(value)
            key isa Symbol ||
                key isa AbstractString ||
                throw(
                    ConvexError(
                        :protocol,
                        "JSON object keys must be strings",
                        nothing,
                        String[],
                    ),
                )
            object[String(key)] = canonicalize_json_value(item)
        end
        return object
    elseif value isa AbstractVector
        return Any[canonicalize_json_value(item) for item in value]
    elseif value isa Bool
        return value
    elseif value isa Integer
        typemin(Int) <= value <= typemax(Int) ||
            throw(ConvexError(:protocol, "JSON integer is out of range", nothing, String[]))
        return Int(value)
    elseif value isa AbstractFloat
        return Float64(value)
    elseif value isa AbstractString
        return String(value)
    elseif value === nothing
        return nothing
    end
    throw(
        ConvexError(
            :protocol,
            "unsupported JSON value type $(typeof(value))",
            nothing,
            String[],
        ),
    )
end

function validated_logs(@nospecialize(items))
    items isa AbstractVector ||
        throw(ConvexError(:protocol, "logLines must be an array", nothing, String[]))
    all(item -> item isa AbstractString, items) ||
        throw(ConvexError(:protocol, "logLines entries must be strings", nothing, String[]))
    return String[String(item) for item in items]
end

function wire_int(@nospecialize(value), label::AbstractString)
    value isa Integer ||
        throw(ConvexError(:protocol, "$(label) must be an integer", nothing, String[]))
    # Convex's sync queryId, querySet, and identity fields are unsigned 32-bit
    # wire values. Keep the bound explicit even on 64-bit Julia so a large
    # JSON integer cannot become a locally valid but protocol-invalid key.
    0 <= value <= typemax(UInt32) ||
        throw(ConvexError(:protocol, "$(label) is out of range", nothing, String[]))
    return Int(value)
end

function timestamp_value(encoded::AbstractString)
    bytes = try
        base64decode(encoded)
    catch
        throw(
            ConvexError(
                :protocol,
                "timestamp must be canonical base64 uint64",
                nothing,
                String[],
            ),
        )
    end
    length(bytes) == 8 && base64encode(bytes) == encoded || throw(
        ConvexError(
            :protocol,
            "timestamp must be canonical base64 uint64",
            nothing,
            String[],
        ),
    )
    value = UInt64(0)
    for (index, byte) in enumerate(bytes)
        value |= UInt64(byte) << (8 * (index - 1))
    end
    return value
end

function whole_count(@nospecialize(value), label::AbstractString)
    value isa Integer && typemin(Int) <= value <= typemax(Int) && return Int(value)
    value isa AbstractFloat &&
        isfinite(value) &&
        trunc(value) == value &&
        typemin(Int) <= value <= typemax(Int) &&
        return Int(value)
    throw(
        ConvexError(
            :protocol,
            "$(label) was not an in-range whole number",
            nothing,
            String[],
        ),
    )
end

end # module Convex
