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
