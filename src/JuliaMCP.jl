module JuliaMCP

using FileWatching: FDWatcher
using JSON

include("fdio.jl")
include("session.jl")
include("server.jl")

end
