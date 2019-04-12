module Registrator

import Base: PkgId

include("slack.jl")
include("regedit/RegEdit.jl")
include("Server.jl")
include("WebUI.jl")

end # module
