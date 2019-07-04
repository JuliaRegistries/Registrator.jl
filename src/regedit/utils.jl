showsafe(x) = (x === nothing) ? "nothing" : x

function gitcmd(path::AbstractString, gitconfig::Dict)
    cmd = ["git", "-C", path]
    for (n,v) in gitconfig
        push!(cmd, "-c")
        push!(cmd, "$n=$v")
    end
    Cmd(cmd)
end

"""
    registration_branch(pkg::Pkg.Types.Project) -> String

Generate the name for the registry branch used to register the package version.
"""
function registration_branch(pkg::Pkg.Types.Project)
    return "registrator/$(lowercase(pkg.name))/$(string(pkg.uuid)[1:8])/v$(pkg.version)"
end
