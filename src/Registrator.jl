module Registrator

using UUIDs, LibGit2

import Base: PkgId

include("slack.jl")
include("regedit/RegEdit.jl")
include("pull_request.jl")
include("Server.jl")
include("WebUI.jl")

end # module
