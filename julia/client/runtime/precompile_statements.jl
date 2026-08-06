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
