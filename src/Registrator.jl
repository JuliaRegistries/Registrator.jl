module Registrator

using UUIDs, LibGit2, DataStructures

import Base: PkgId

const DEFAULT_REGISTRY = "https://github.com/JuliaRegistries/General"
const REGISTRIES = Dict{String,UUID}()

include("slack.jl")
include("builtin_pkgs.jl")
include("regedit/RegEdit.jl")
include("Server.jl")

end # module
