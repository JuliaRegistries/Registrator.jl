module RegEdit

export RegBranch
export register

using AutoHashEquals
using LibGit2
using Pkg: Pkg, TOML, GitTools
using UUIDs

const DEFAULT_REGISTRY_URL = "https://github.com/JuliaRegistries/General"

include("types.jl")
include("register.jl")
include("utils.jl")

end
