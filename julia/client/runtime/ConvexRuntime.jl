module ConvexRuntime

# Load one shared client module. Both included programs see this binding and
# skip their standalone include, avoiding duplicate client code in the image.
include(joinpath(@__DIR__, "..", "client", "Convex.jl"))

# These nested modules include the exact adapter and canonical example sources
# copied into PackageCompiler's temporary build tree by the Dockerfile. Keeping
# them separate avoids loading the Convex module twice into one namespace.
module AdapterProgram
using ..Convex
include(joinpath(@__DIR__, "..", "client", "tests", "conformance", "adapter.jl"))
end

module ExampleProgram
using ..Convex
include(joinpath(@__DIR__, "..", "examples", "basics", "main.jl"))
end

function adapter_main()::Cint
    if haskey(ENV, "ADAPTER_LISTEN")
        host, port = AdapterProgram.parse_listen_address(ENV["ADAPTER_LISTEN"])
        server =
            AdapterProgram.listen(AdapterProgram.parse(AdapterProgram.IPAddr, host), port)
        socket = AdapterProgram.accept(server)
        AdapterProgram.close(server)
        try
            AdapterProgram.run_adapter(socket, socket)
        finally
            AdapterProgram.close(socket)
        end
    else
        AdapterProgram.run_adapter(stdin, stdout)
    end
    return 0
end

function example_main()::Cint
    room = get(ENV, "EXAMPLE_ROOM", "julia-example")
    ExampleProgram.run_example(room)
    return 0
end

end
