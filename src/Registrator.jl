module Registrator

using Base64
using LibGit2
using UUIDs
import RegistryTools

# Remove all of a base64 string's whitespace before decoding it.
decodeb64(s::AbstractString) = String(base64decode(replace(s, r"\s" => "")))


struct RegisterParams
    package_repo::String
    pkg::RegistryTools.Project
    tree_sha::String
    registry::String
    registry_fork::String
    registry_deps::Vector{<:String}
    subdir::String
    push::Bool
    gitconfig::Dict
end

RegisterParams(
    package_repo::AbstractString,
    pkg::RegistryTools.Project,
    tree_sha::AbstractString;
    subdir::AbstractString="",
    registry::AbstractString="",
    registry_fork::AbstractString="",
    registry_deps::Vector{<:AbstractString}=[],
    push::Bool=false,
    gitconfig::Dict=Dict(),
) = RegisterParams(
    package_repo,
    pkg,
    tree_sha,
    registry,
    registry_fork,
    registry_deps,
    subdir,
    push,
    gitconfig,
)

RegistryTools.register(regp::RegisterParams) = RegistryTools.register(regp.package_repo, regp.pkg, regp.tree_sha;
                                          registry=regp.registry, registry_fork=regp.registry_fork,
                                          registry_deps=regp.registry_deps,
                                          subdir=regp.subdir, push=regp.push, gitconfig=regp.gitconfig,)

include("slack.jl")
include("pull_request.jl")
include("Messaging.jl")
include("RegService.jl")
include("commentbot/CommentBot.jl")
include("webui/WebUI.jl")

end # module
