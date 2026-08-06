#!/usr/local/bin/julia

# PackageCompiler's generated runtime includes this file inside a module that
# already loaded the client, so only a direct `julia adapter.jl` run needs its
# own include.
isdefined(@__MODULE__, :Convex) || include(joinpath(@__DIR__, "..", "..", "Convex.jl"))
using .Convex
using JSON3
using Sockets

const MAX_NDJSON_BYTES = 1024 * 1024
# The writer's in-flight record remains charged here. Seven retained records
# plus five client records leave four explicit slots for the relay, decoder,
# client queue candidate, and adapter encoding candidate.
const MAX_OUTPUT_ITEMS = 7
const MAX_OUTPUT_BYTES = 3 * 1024 * 1024
const MAX_TRANSIENT_ITEMS = 4
const MAX_TRANSIENT_ENCODED_BYTES = 4 * Convex.MAX_LIVE_BYTES
# HTTP handling may simultaneously retain the bounded response bytes, its JSON
# text/backing storage, and the decoded result until adapter encoding completes.
const MAX_HTTP_TRANSIENT_BYTES = 3 * Convex.MAX_HTTP_BYTES
const MAX_SERIALIZED_PIPELINE_BYTES =
    Convex.MAX_QUEUE_BYTES +
    MAX_OUTPUT_BYTES +
    MAX_TRANSIENT_ENCODED_BYTES +
    MAX_HTTP_TRANSIENT_BYTES
const MAX_EVENT_BYTES = Convex.MAX_LIVE_BYTES + 64 * 1024
const TEST_RELAY_DEQUEUED = Ref{Any}(nothing)
const TEST_RELAY_RELEASE = Ref{Any}(nothing)

struct OutputRecord
    bytes::Vector{UInt8}
    subscription_id::Union{Nothing,String}
    generation::UInt64
end

mutable struct OutputPump
    io::IO
    lock::ReentrantLock
    queue::Vector{OutputRecord}
    active_generations::Dict{String,UInt64}
    encoded_bytes::Int
    buffered_items::Int
    closing::Bool
    failed::Bool
    interrupt_on_failure::Bool
    controller_task::Task
    writer::Task
end

function OutputPump(io::IO; interrupt_on_failure = true)
    pump = OutputPump(
        io,
        ReentrantLock(),
        OutputRecord[],
        Dict{String,UInt64}(),
        0,
        0,
        false,
        false,
        interrupt_on_failure,
        current_task(),
        current_task(),
    )
    pump.writer = @async output_writer(pump)
    return pump
end

function bounded_write(io::IO, bytes::Vector{UInt8}; timeout = 2.0)
    if !Sys.islinux()
        write(io, bytes)
        flush(io)
        return nothing
    end
    descriptor = if applicable(Base.fd, io)
        Base.fd(io)
    elseif hasproperty(io, :handle)
        result = Ref{Cint}(-1)
        ccall(:uv_fileno, Cint, (Ptr{Cvoid}, Ptr{Cint}), io.handle, result) == 0 ||
            throw(SystemError("uv_fileno", true))
        result[]
    else
        write(io, bytes)
        flush(io)
        return nothing
    end
    is_socket = io isa Sockets.TCPSocket
    original_flags = Cint(-1)
    if !is_socket
        original_flags = ccall(:fcntl, Cint, (Cint, Cint), descriptor, 3)
        original_flags >= 0 || throw(SystemError("fcntl(F_GETFL)", true))
        ccall(:fcntl, Cint, (Cint, Cint, Cint), descriptor, 4, original_flags | 0x800) >=
        0 || throw(SystemError("fcntl(F_SETFL)", true))
    end
    try
        offset = 1
        deadline = time() + timeout
        while offset <= length(bytes)
            time() < deadline || throw(
                ConvexError(
                    :transport,
                    "adapter output write timed out",
                    nothing,
                    String[],
                ),
            )
            written = GC.@preserve bytes if is_socket
                # Per-call flags bound the send without changing the shared
                # socket's receive mode while the controller task is reading.
                ccall(
                    :send,
                    Cssize_t,
                    (Cint, Ptr{UInt8}, Csize_t, Cint),
                    descriptor,
                    pointer(bytes, offset),
                    length(bytes) - offset + 1,
                    0x40 | 0x4000, # MSG_DONTWAIT | MSG_NOSIGNAL on Linux
                )
            else
                ccall(
                    :write,
                    Cssize_t,
                    (Cint, Ptr{UInt8}, Csize_t),
                    descriptor,
                    pointer(bytes, offset),
                    length(bytes) - offset + 1,
                )
            end
            if written > 0
                offset += Int(written)
            elseif written == 0
                time() < deadline || throw(
                    ConvexError(
                        :transport,
                        "adapter output write timed out",
                        nothing,
                        String[],
                    ),
                )
                sleep(0.001)
            elseif written < 0 && Base.Libc.errno() in (11, 35)
                time() < deadline || throw(
                    ConvexError(
                        :transport,
                        "adapter output write timed out",
                        nothing,
                        String[],
                    ),
                )
                sleep(0.001)
            elseif written < 0 && Base.Libc.errno() == 4
                continue
            elseif written < 0
                throw(SystemError("adapter output write", true))
            end
        end
    finally
        if !is_socket && original_flags >= 0
            ccall(:fcntl, Cint, (Cint, Cint, Cint), descriptor, 4, original_flags) >= 0 ||
                throw(SystemError("fcntl(F_SETFL restore)", true))
        end
    end
    return nothing
end

function encode_event(event)
    encoded = Vector{UInt8}(JSON3.write(event) * "\n")
    length(encoded) <= MAX_EVENT_BYTES ||
        throw(ConvexError(:protocol, "adapter event exceeds byte limit", nothing, String[]))
    return encoded
end

function enqueue_locked!(pump::OutputPump, record::OutputRecord)
    record_size = length(record.bytes)
    while !isempty(pump.queue) && (
        pump.buffered_items >= MAX_OUTPUT_ITEMS ||
        pump.encoded_bytes + record_size > MAX_OUTPUT_BYTES
    )
        removable = findfirst(item -> !isnothing(item.subscription_id), pump.queue)
        isnothing(removable) && return false
        removed = popat!(pump.queue, removable)
        pump.encoded_bytes -= length(removed.bytes)
        pump.buffered_items -= 1
    end
    if pump.buffered_items >= MAX_OUTPUT_ITEMS ||
       pump.encoded_bytes + record_size > MAX_OUTPUT_BYTES
        # The one in-flight write is also part of the global budget. If it alone
        # leaves no room, dropping this record preserves the hard memory bound.
        return false
    end
    push!(pump.queue, record)
    pump.encoded_bytes += record_size
    pump.buffered_items += 1
    return true
end

function write_event(
    pump::OutputPump,
    event;
    subscription_id = nothing,
    generation = UInt64(0),
)
    record = OutputRecord(encode_event(event), subscription_id, generation)
    if !isnothing(subscription_id)
        return lock(pump.lock) do
            (pump.closing || pump.failed) && return false
            get(pump.active_generations, subscription_id, UInt64(0)) == generation ||
                return false
            enqueue_locked!(pump, record)
        end
    end
    enqueue_critical!(pump, record)
    return true
end

function enqueue_critical!(pump::OutputPump, record::OutputRecord; timeout = 2.5)
    deadline = time() + timeout
    while true
        accepted = lock(pump.lock) do
            (pump.closing || pump.failed) && throw(
                ConvexError(
                    :transport,
                    "adapter output stream is closed",
                    nothing,
                    String[],
                ),
            )
            enqueue_locked!(pump, record)
        end
        accepted && return nothing
        time() < deadline || throw(
            ConvexError(
                :transport,
                "adapter output backpressure timed out",
                nothing,
                String[],
            ),
        )
        sleep(0.001)
    end
end

function activate_and_ack!(
    pump::OutputPump,
    subscription_id::String,
    generation::Integer,
    id::String,
)
    generation_value = UInt64(generation)
    record =
        OutputRecord(encode_event(Dict("id" => id, "type" => "ack")), nothing, UInt64(0))
    lock(pump.lock) do
        pump.active_generations[subscription_id] = generation_value
    end
    enqueue_critical!(pump, record)
    return nothing
end

function invalidate_generation!(pump::OutputPump, subscription_id::String)
    lock(pump.lock) do
        delete!(pump.active_generations, subscription_id)
    end
    return nothing
end

function write_ack(pump::OutputPump, id::String)
    record =
        OutputRecord(encode_event(Dict("id" => id, "type" => "ack")), nothing, UInt64(0))
    enqueue_critical!(pump, record)
    return nothing
end

function invalidate_and_ack!(pump::OutputPump, subscription_id::String, id::String)
    invalidate_generation!(pump, subscription_id)
    write_ack(pump, id)
    return nothing
end

function output_writer(pump::OutputPump)
    while true
        record = lock(pump.lock) do
            if isempty(pump.queue)
                pump.closing && return nothing
                return missing
            end
            popfirst!(pump.queue)
        end
        record === nothing && return nothing
        if record === missing
            sleep(0.001)
            continue
        end
        valid = lock(pump.lock) do
            isnothing(record.subscription_id) ||
                get(pump.active_generations, record.subscription_id, UInt64(0)) ==
                record.generation
        end
        try
            valid && bounded_write(pump.io, record.bytes)
        catch
            lock(pump.lock) do
                pump.failed = true
                pump.closing = true
                for queued in pump.queue
                    pump.encoded_bytes -= length(queued.bytes)
                    pump.buffered_items -= 1
                end
                empty!(pump.queue)
            end
            if pump.interrupt_on_failure && !istaskdone(pump.controller_task)
                schedule(
                    pump.controller_task,
                    ConvexError(
                        :transport,
                        "adapter output stream failed",
                        nothing,
                        String[],
                    );
                    error = true,
                )
            end
        finally
            lock(pump.lock) do
                pump.encoded_bytes -= length(record.bytes)
                pump.buffered_items -= 1
            end
        end
    end
end

function stop_output!(pump::OutputPump; timeout = 3.0)
    lock(pump.lock) do
        empty!(pump.active_generations)
        pump.closing = true
    end
    return timedwait(() -> istaskdone(pump.writer), timeout; pollint = 0.002) == :ok
end

function serialise_error(error)
    if error isa ConvexError
        name =
            error.kind == :function_error ? "FunctionError" :
            error.kind == :protocol ? "ProtocolError" :
            error.kind == :transport ? "TransportError" : "Error"
        event = Dict{String,Any}("name" => name, "message" => error.message)
        error.data === nothing || (event["data"] = error.data)
        return event
    end
    return Dict("name" => "Error", "message" => sprint(showerror, error))
end

function failure(
    pump::OutputPump,
    id,
    error;
    subscription_id = nothing,
    generation = UInt64(0),
)
    event =
        isnothing(subscription_id) ?
        Dict{String,Any}("type" => "error", "error" => serialise_error(error)) :
        Dict{String,Any}(
            "type" => "subscription",
            "subscriptionId" => subscription_id,
            "error" => serialise_error(error),
        )
    isnothing(id) || (event["id"] = id)
    if error isa ConvexError && !isempty(error.logs)
        event["logs"] = error.logs
    end
    write_event(pump, event; subscription_id, generation)
    return nothing
end

function read_limited_line(io::IO)
    bytes = UInt8[]
    overflow = false
    while !eof(io)
        byte = read(io, UInt8)
        if byte == UInt8('\n')
            overflow && throw(
                ConvexError(
                    :protocol,
                    "NDJSON command exceeds byte limit",
                    nothing,
                    String[],
                ),
            )
            text = String(bytes)
            isvalid(text) || throw(
                ConvexError(
                    :protocol,
                    "NDJSON command was not valid UTF-8",
                    nothing,
                    String[],
                ),
            )
            return text
        end
        if !overflow
            push!(bytes, byte)
            if length(bytes) > MAX_NDJSON_BYTES
                overflow = true
                empty!(bytes) # drain the rest without retaining attacker input
            end
        end
    end
    overflow && throw(
        ConvexError(:protocol, "NDJSON command exceeds byte limit", nothing, String[]),
    )
    isempty(bytes) && return nothing
    text = String(bytes)
    isvalid(text) || throw(
        ConvexError(:protocol, "NDJSON command was not valid UTF-8", nothing, String[]),
    )
    return text
end

function get_client(current)
    current[] !== nothing && return current[]
    url = get(ENV, "CONVEX_URL", "")
    isempty(url) &&
        throw(ConvexError(:transport, "CONVEX_URL is required", nothing, String[]))
    # A malformed deployment URL is an environment fault. Reporting it as a
    # typed protocol error keeps the client's ArgumentError out of the NDJSON
    # stream, where it would serialize as an untyped Error event.
    current[] = try
        Client(url; auth_token = get(ENV, "CONVEX_AUTH_TOKEN", ""))
    catch error
        error isa ConvexError && rethrow()
        throw(ConvexError(:protocol, "CONVEX_URL is not a Convex URL", nothing, String[]))
    end
    return current[]
end

# The controller may omit `path` or send an empty one. Both are protocol faults
# rather than argument bugs in the educational client.
function adapter_path(command)
    path = Convex.jsonget(command, "path", "")
    if !(path isa AbstractString) || isempty(path)
        throw(ConvexError(:protocol, "path must be a non-empty string", nothing, String[]))
    end
    return String(path)
end

function take_available_update(subscription)
    return lock(subscription.budget.lock) do
        isempty(subscription.queue) && return nothing
        queued = popfirst!(subscription.queue)
        index = findfirst(item -> item === queued, subscription.budget.order)
        isnothing(index) || deleteat!(subscription.budget.order, index)
        subscription.budget.encoded_bytes -= queued.encoded_bytes
        return queued.update
    end
end

# One fair dispatcher owns every client-to-adapter dequeue. Per-subscription
# relay tasks could each retain a near-limit value, defeating the global count
# and byte budget even when both queues were independently bounded.
function relay_subscriptions(pump, subscriptions, closing)
    cursor = 1
    try
        while !closing[]
            snapshot = collect(subscriptions)
            if isempty(snapshot)
                sleep(0.002)
                continue
            end
            cursor = mod1(cursor, length(snapshot))
            forwarded = false
            for offset = 0:(length(snapshot)-1)
                index = mod1(cursor + offset, length(snapshot))
                subscription_id, state = snapshot[index]
                update = take_available_update(state.subscription)
                isnothing(update) && continue
                generation = state.generation
                cursor = mod1(index + 1, length(snapshot))
                forwarded = true
                if TEST_RELAY_DEQUEUED[] !== nothing
                    put!(TEST_RELAY_DEQUEUED[], (subscription_id, generation))
                    take!(TEST_RELAY_RELEASE[])
                end
                delay_ms = tryparse(Int, get(ENV, "ADAPTER_TEST_RELAY_DELAY_MS", "0"))
                !isnothing(delay_ms) && delay_ms > 0 && sleep(delay_ms / 1000)
                if update.error === nothing
                    event = Dict{String,Any}(
                        "type" => "subscription",
                        "subscriptionId" => subscription_id,
                        "value" => update.value,
                    )
                    isempty(update.logs) || (event["logs"] = update.logs)
                    write_event(pump, event; subscription_id, generation)
                else
                    failure(pump, nothing, update.error; subscription_id, generation)
                end
                break
            end
            forwarded || sleep(0.002)
        end
    catch error
        error isa Core.MissingCodeError && rethrow()
        closing[] || failure(pump, nothing, error)
    end
    return nothing
end

function command_id(command)
    id = Convex.jsonget(command, "id", nothing)
    id isa AbstractString && !isempty(id) ||
        throw(ConvexError(:protocol, "adapter command id is required", nothing, String[]))
    return String(id)
end

function command_args(command)
    args = Convex.jsonget(command, "args", Dict{String,Any}())
    args isa AbstractDict ||
        throw(ConvexError(:protocol, "args must be a JSON object", nothing, String[]))
    # Collapse JSON3.Object / mixed key shapes into the client's one concrete
    # Dict{String,Any} tree before Subscribe reaches the stripped AOT image.
    return Convex.canonicalize_args(args)
end

function next_adapter_generation!(counter::Base.RefValue{UInt64})
    counter[] == typemax(UInt64) && throw(
        ConvexError(
            :closed,
            "adapter subscription generation space exhausted",
            nothing,
            String[],
        ),
    )
    counter[] += UInt64(1)
    return counter[]
end

function run_adapter(input::IO, output::IO)
    pump = OutputPump(output)
    current = Ref{Union{Nothing,Client}}(nothing)
    subscriptions = Dict{String,Any}()
    generation_counter = Ref(UInt64(0))
    relay_closing = Ref(false)
    relay = @async relay_subscriptions(pump, subscriptions, relay_closing)
    try
        while true
            line = try
                read_limited_line(input)
            catch error
                error isa Core.MissingCodeError && rethrow()
                failure(pump, nothing, error)
                continue
            end
            line === nothing && break
            isempty(strip(line)) && continue
            command = try
                JSON3.read(line)
            catch error
                error isa Core.MissingCodeError && rethrow()
                failure(
                    pump,
                    nothing,
                    ConvexError(:protocol, sprint(showerror, error), nothing, String[]),
                )
                continue
            end
            if !(command isa AbstractDict)
                failure(
                    pump,
                    nothing,
                    ConvexError(
                        :protocol,
                        "adapter command must be a JSON object",
                        nothing,
                        String[],
                    ),
                )
                continue
            end
            id = try
                command_id(command)
            catch error
                error isa Core.MissingCodeError && rethrow()
                failure(pump, nothing, error)
                continue
            end
            try
                operation = Convex.jsonget(command, "op", "")
                operation isa AbstractString || throw(
                    ConvexError(
                        :protocol,
                        "adapter op must be a string",
                        nothing,
                        String[],
                    ),
                )
                if operation == "hello"
                    Convex.jsonget(command, "protocolVersion", 0) == 1 || throw(
                        ConvexError(
                            :protocol,
                            "unsupported adapter protocol version",
                            nothing,
                            String[],
                        ),
                    )
                    write_event(
                        pump,
                        Dict(
                            "protocolVersion" => 1,
                            "id" => id,
                            "type" => "ready",
                            "language" => "julia",
                            # Derive provenance from the running toolchain so a
                            # rebuild can never report a version it is not.
                            "implementation" => "native-julia-" * string(VERSION),
                            "runtime" => "julia-" * string(VERSION),
                        ),
                    )
                elseif operation in ("query", "mutation", "action")
                    path = adapter_path(command)
                    result = getfield(Convex, Symbol(operation))(
                        get_client(current),
                        path,
                        command_args(command),
                    )
                    event = Dict{String,Any}(
                        "id" => id,
                        "type" => "result",
                        "value" => result.value,
                    )
                    isempty(result.logs) || (event["logs"] = result.logs)
                    write_event(pump, event)
                elseif operation == "setAuth"
                    token = Convex.jsonget(command, "token", nothing)
                    token isa AbstractString || throw(
                        ConvexError(:protocol, "token must be a string", nothing, String[]),
                    )
                    set_auth!(get_client(current), String(token))
                    write_event(pump, Dict("id" => id, "type" => "ack"))
                elseif operation == "subscribe"
                    subscription_id_value =
                        Convex.jsonget(command, "subscriptionId", nothing)
                    subscription_id_value isa AbstractString &&
                    !isempty(subscription_id_value) || throw(
                        ConvexError(
                            :protocol,
                            "subscriptionId is required",
                            nothing,
                            String[],
                        ),
                    )
                    subscription_id = String(subscription_id_value)
                    if haskey(subscriptions, subscription_id)
                        # Invalidate before entering the client's Remove
                        # barrier. If that barrier fails, no replacement ACK
                        # is emitted and the old relay remains suppressed.
                        invalidate_generation!(pump, subscription_id)
                        previous = subscriptions[subscription_id]
                        unsubscribe!(previous.subscription)
                        delete!(subscriptions, subscription_id)
                    end
                    generation = next_adapter_generation!(generation_counter)
                    path = adapter_path(command)
                    subscription =
                        subscribe(get_client(current), path, command_args(command))
                    try
                        activate_and_ack!(pump, subscription_id, generation, id)
                    catch
                        # No acknowledgement reached the controller, so retire
                        # this subscription instead of leaving a live relay the
                        # controller can neither observe nor unsubscribe.
                        invalidate_generation!(pump, subscription_id)
                        unsubscribe!(subscription)
                        rethrow()
                    end
                    subscriptions[subscription_id] =
                        (subscription = subscription, generation = generation)
                elseif operation == "unsubscribe"
                    subscription_id_value =
                        Convex.jsonget(command, "subscriptionId", nothing)
                    subscription_id_value isa AbstractString &&
                    !isempty(subscription_id_value) || throw(
                        ConvexError(
                            :protocol,
                            "subscriptionId is required",
                            nothing,
                            String[],
                        ),
                    )
                    subscription_id = String(subscription_id_value)
                    invalidate_generation!(pump, subscription_id)
                    if haskey(subscriptions, subscription_id)
                        previous = subscriptions[subscription_id]
                        unsubscribe!(previous.subscription)
                        delete!(subscriptions, subscription_id)
                    end
                    # The client owner has now flushed Remove (when needed).
                    # Only now may the controller observe the acknowledgement.
                    write_ack(pump, id)
                elseif operation == "debugDisconnect"
                    debug_disconnect_for_adapter(get_client(current))
                    write_event(pump, Dict("id" => id, "type" => "ack"))
                elseif operation == "close"
                    lock(pump.lock) do
                        empty!(pump.active_generations)
                    end
                    cleanup_error = nothing
                    if current[] !== nothing
                        try
                            close!(current[])
                        catch error
                            error isa Core.MissingCodeError && rethrow()
                            cleanup_error = error
                        end
                    end
                    empty!(subscriptions)
                    isnothing(cleanup_error) || failure(pump, id, cleanup_error)
                    write_event(pump, Dict("id" => id, "type" => "closed"))
                    break
                else
                    throw(
                        ConvexError(
                            :protocol,
                            "unknown adapter operation",
                            nothing,
                            String[],
                        ),
                    )
                end
            catch error
                error isa Core.MissingCodeError && rethrow()
                failure(pump, id, error)
            end
        end
    catch error
        # Once the output endpoint is gone there is nowhere to report another
        # protocol event. Treat the bounded writer's interrupt as controller
        # EOF and still run the complete client, relay, and writer cleanup.
        error isa ConvexError && error.kind == :transport && pump.failed || rethrow()
    finally
        relay_closing[] = true
        lock(pump.lock) do
            empty!(pump.active_generations)
        end
        # One owner close retires every active subscription together. Calling
        # unsubscribe sequentially could otherwise cost 16 close deadlines.
        current[] === nothing || try
            close!(current[])
        catch
        end
        timedwait(() -> istaskdone(relay), 0.5; pollint = 0.002) == :ok || throw(
            ConvexError(
                :transport,
                "adapter relay dispatcher did not stop",
                nothing,
                String[],
            ),
        )
        stop_output!(pump) || throw(
            ConvexError(
                :transport,
                "adapter output writer did not stop",
                nothing,
                String[],
            ),
        )
    end
    return nothing
end

function parse_listen_address(value::String)
    pieces = split(value, ':'; limit = 2)
    length(pieces) == 2 || throw(ArgumentError("ADAPTER_LISTEN must use host:port"))
    port = try
        parse(Int, pieces[2])
    catch
        throw(ArgumentError("ADAPTER_LISTEN must use host:port"))
    end
    0 <= port <= 65535 || throw(ArgumentError("ADAPTER_LISTEN port is invalid"))
    return pieces[1], port
end

if abspath(PROGRAM_FILE) == @__FILE__
    if haskey(ENV, "ADAPTER_LISTEN")
        host, port = parse_listen_address(ENV["ADAPTER_LISTEN"])
        server = listen(parse(IPAddr, host), port)
        socket = accept(server)
        close(server)
        try
            run_adapter(socket, socket)
        finally
            close(socket)
        end
    else
        run_adapter(stdin, stdout)
    end
end
