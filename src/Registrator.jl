module Registrator

using UUIDs, LibGit2

import Base: PkgId

include("slack.jl")
include("regedit/RegEdit.jl")
include("Server.jl")

end # module
