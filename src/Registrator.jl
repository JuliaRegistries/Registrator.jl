module Registrator

using Base64
using LibGit2
using UUIDs

# Remove all of a base64 string's whitespace before decoding it.
decodeb64(s::AbstractString) = String(base64decode(replace(s, r"\s" => "")))

include("slack.jl")
include("regedit/RegEdit.jl")
include("pull_request.jl")
include("Messaging.jl")
include("RegService.jl")
include("commentbot/CommentBot.jl")
include("webui/WebUI.jl")

end # module
