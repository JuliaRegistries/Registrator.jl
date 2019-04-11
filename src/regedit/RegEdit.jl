module RegEdit

export RegBranch
export register

using AutoHashEquals
using Pkg: Pkg, TOML, GitTools
using UUIDs

include("types.jl")
include("register.jl")
include("utils.jl")

end
