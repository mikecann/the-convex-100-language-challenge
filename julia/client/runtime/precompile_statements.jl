# Precompile statements PackageCompiler's execution trace cannot discover.
#
# The adapter serializes every protocol event from a Dict{String,Any}, so JSON3
# resolves each value's StructType by dynamic dispatch on the runtime value.
# Running that code under --trace-compile devirtualizes the lookup, so the
# trace records JSON3's writer for a concrete value type but never the
# StructTypes.StructType(value) instance the dispatch itself needs. The final
# app disables runtime compilation, so the first Convex response carrying log
# lines died with:
#
#   Core.MissingCodeError(mi=(::Type{StructTypes.StructType})(Array{String, 1}))
#
# PackageCompiler replays this file one statement per line, so every statement
# must stay on a single line to be parsed.
precompile(Tuple{Type{StructTypes.StructType},Array{String,1}})
precompile(Tuple{Type{StructTypes.StructType},Array{Any,1}})
precompile(Tuple{Type{StructTypes.StructType},Base.Dict{String,Any}})
# call()'s non-2xx HTTP status branch is the one place a ConvexError carries a
# raw Dict literal as `data` instead of a canonicalize_json_value-normalized
# Dict{String,Any}: `Dict("status" => response_status)`. Executing that exact
# path (see precompile_adapter.jl's send_http_unauthorized workout) still left
# the stripped image without StructTypes.StructType(Dict{String,Int64}) --
# the same devirtualized-dispatch gap the comment above already describes, so
# it needs the same explicit treatment.
precompile(Tuple{Type{StructTypes.StructType},Base.Dict{String,Int64}})
precompile(Tuple{Type{StructTypes.StructType},String})
precompile(Tuple{Type{StructTypes.StructType},Int64})
precompile(Tuple{Type{StructTypes.StructType},Float64})
precompile(Tuple{Type{StructTypes.StructType},Bool})
precompile(Tuple{Type{StructTypes.StructType},Nothing})
# The canonical example prints its transcript to whatever stdout the container
# gave it: a pipe under `docker run`, a file when the caller redirects, a tty
# when someone runs it by hand.
precompile(Tuple{typeof(println),Base.PipeEndpoint,String})
precompile(Tuple{typeof(println),Base.IOStream,String})
precompile(Tuple{typeof(println),Base.TTY,String})
precompile(Tuple{typeof(print),Base.PipeEndpoint,String})
precompile(Tuple{typeof(print),Base.IOStream,String})
precompile(Tuple{typeof(print),Base.TTY,String})
# A MissingCodeError reaching the process top level is itself reported through
# generic Julia runtime machinery, and that reporting path is exactly as
# unspecialized as anything above -- it is not exempt just because it is the
# thing printing the fatal error. A hosted run that hit an uncovered command
# specialization died a second time trying to report the first failure, with
# the runtime's own uncaught-exception handler unable to dispatch
# `hasproperty` on the Core.MissingCodeError instance it was trying to
# describe. Nothing in this file's execution workout can construct a real
# Core.MissingCodeError under a normal JIT-enabled run to discover this by
# tracing, so it must be pinned explicitly: whatever else stays uncovered,
# the process must still be able to report that fact instead of double-faulting.
precompile(Tuple{typeof(hasproperty),Core.MissingCodeError,Symbol})
# Observed as a second, independent double-fault while reproducing the above:
# forcibly terminating the adapter mid-request hit an atexit hook that could
# not report a plain ErrorException on the concrete PipeEndpoint stdout Docker
# gives the container, for the same reason -- showerror's generic IO fallback
# had no compiled code for that pairing. Same unreachable-by-tracing situation
# as above, so it is pinned the same way.
precompile(Tuple{typeof(showerror),Base.PipeEndpoint,ErrorException})
# A third, more specific gap in that same reporting chain: printing a real
# failed-task exception stack (see precompile_adapter.jl's synthetic
# Core.MissingCodeError-in-a-Task block) still crashed on
# print(::IOContext{IOBuffer}, ::Symbol) -- the call that prints a
# MethodInstance's function name while showing the MissingCodeError it
# wraps. --trace-compile never reports this one as newly compiled even
# though the synthetic block genuinely executes it, because it is already
# native code in the ordinary Julia sysimage the workout runs under; the
# stripped app's own minimal sysimage does not inherit that for free and
# needs it listed explicitly, exactly like the StructType gaps above.
precompile(Tuple{typeof(print),Base.IOContext{Base.IOBuffer},Symbol})
# The rest of that same reporting chain, captured in one pass by running
# precompile_adapter.jl's synthetic MissingCodeError-in-a-Task block under
# --trace-compile in a *fresh* interpreter (one that had not already warmed
# up this machinery some other way) rather than continuing to discover one
# more missing piece per rebuild: constructing the error and the failed
# task, showerror on the resulting TaskFailedException, destructuring its
# exception-stack entry, sizing/showing the MissingCodeError struct itself,
# showing the MethodInstance it wraps (including the colored qualified-name
# printer), building the StackFrame entries for its Base.InterpreterIP
# backtrace (this workout's own top-level code is interpreted, so that is
# the concrete backtrace element type produced), and the colored
# "nested task error:" prefix. Each is its own MethodInstance the stripped
# sysimage does not inherit from the ordinary Julia one for free.
#! format: off
# These stay single-line and outside JuliaFormatter's control on purpose --
# see the file header. JuliaFormatter's own line-length wrapping would
# otherwise split a single precompile() statement across multiple lines,
# which breaks PackageCompiler's line-based replay of this file.
precompile(Tuple{Type{Core.MissingCodeError},Core.MethodInstance})
precompile(Tuple{Type{Base.IOContext{IO_t} where {IO_t<:IO}},Base.IOBuffer})
precompile(Tuple{typeof(showerror),Base.IOContext{Base.IOBuffer},Base.TaskFailedException})
precompile(Tuple{typeof(indexed_iterate),NamedTuple{(:exception, :backtrace),Tuple{Core.MissingCodeError,Vector{Union{Ptr{Nothing},Base.InterpreterIP}}}},Int})
precompile(Tuple{typeof(indexed_iterate),NamedTuple{(:exception, :backtrace),Tuple{Core.MissingCodeError,Vector{Union{Ptr{Nothing},Base.InterpreterIP}}}},Int,Int})
precompile(Tuple{typeof(Core.kwcall),NamedTuple{(:backtrace,),Tuple{Bool}},typeof(showerror),Base.IOContext{Base.IOBuffer},Core.MissingCodeError,Vector{Union{Ptr{Nothing},Base.InterpreterIP}}})
# A racing debugDisconnect (send it before the initial hydration value even
# arrives, then immediately reconnect against a peer that has already gone
# away) reached the same indexed_iterate/kwcall-showerror gap for a genuine
# UndefVarError instead of a MissingCodeError -- the same
# devirtualized-per-exception-type dispatch as above, just for whichever raw
# exception actually reaches an unprotected corner of live_worker_loop!
# (rather than the ConvexError typed_error() normally converts everything
# to). The StackFrame/printstyled/with_output_color/print(String,Type,...)
# machinery a few lines above is exception-type-independent and already
# covers this case; only the exception-typed pieces need repeating here.
precompile(Tuple{typeof(indexed_iterate),NamedTuple{(:exception, :backtrace),Tuple{UndefVarError,Vector{Union{Ptr{Nothing},Base.InterpreterIP}}}},Int})
precompile(Tuple{typeof(indexed_iterate),NamedTuple{(:exception, :backtrace),Tuple{UndefVarError,Vector{Union{Ptr{Nothing},Base.InterpreterIP}}}},Int,Int})
precompile(Tuple{typeof(Core.kwcall),NamedTuple{(:backtrace,),Tuple{Bool}},typeof(showerror),Base.IOContext{Base.IOBuffer},UndefVarError,Vector{Union{Ptr{Nothing},Base.InterpreterIP}}})
# A distinct crash in the same "print a real backtrace" family, this time
# reached genuinely delivering a Live QueryFailed transition (the
# client/live/query-error-recovery flow): a stack frame for a keyword-method
# call with zero keyword arguments prints its @Kwargs{} type annotation via
# show_at_namedtuple(io, (), Tuple{}), which was never compiled for the
# empty-tuple case. Same unreachable-by-tracing situation as the rest of
# this backtrace-printing family.
precompile(Tuple{typeof(Base.show_at_namedtuple),Base.IOContext{Base.IOBuffer},Tuple{},DataType})
precompile(Tuple{typeof(sizeof),Core.MissingCodeError})
precompile(Tuple{typeof(show),Base.IOContext{Base.IOBuffer},Core.MethodInstance})
precompile(Tuple{typeof(Core.kwcall),NamedTuple{(:use_color,),Tuple{Bool}},typeof(Base.print_type_bicolor),Base.IOContext{Base.IOBuffer},Type})
precompile(Tuple{Type{Base.StackTraces.StackFrame},Symbol,Symbol,Int,Core.MethodInstance,Bool,Bool,UInt64})
precompile(Tuple{Type{Base.StackTraces.StackFrame},Symbol,Symbol,Int,Nothing,Bool,Bool,UInt64})
precompile(Tuple{typeof(indexed_iterate),Tuple{Base.StackTraces.StackFrame,Int},Int})
precompile(Tuple{typeof(indexed_iterate),Tuple{Base.StackTraces.StackFrame,Int},Int,Int})
precompile(Tuple{typeof(Core.kwcall),NamedTuple{(:color, :bold),Tuple{Symbol,Bool}},typeof(printstyled),Base.IOContext{Base.IOBuffer},String,Vararg{Any}})
precompile(Tuple{typeof(Core.kwcall),NamedTuple{(:bold, :italic, :underline, :blink, :reverse, :hidden),NTuple{6,Bool}},typeof(Base.with_output_color),Function,Symbol,Base.IOContext{Base.IOBuffer},String,Vararg{Any}})
precompile(Tuple{typeof(print),Base.IOContext{Base.IOBuffer},String,Type,Vararg{Any}})
#! format: on
