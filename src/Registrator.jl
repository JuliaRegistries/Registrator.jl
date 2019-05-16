module Registrator

using UUIDs, LibGit2

import Base: PkgId

include("slack.jl")
include("regedit/RegEdit.jl")
include("pull_request.jl")
include("Messaging.jl")
include("RegService.jl")
include("commentbot/CommentBot.jl")
include("webui/WebUI.jl")

end # module
