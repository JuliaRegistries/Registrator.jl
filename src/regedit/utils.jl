showsafe(x) = (x === nothing) ? "nothing" : x

function gitcmd(path::String, gitconfig::Dict)
    cmd = ["git", "-C", path]
    for (n,v) in gitconfig
        push!(cmd, "-c")
        push!(cmd, "$n=$v")
    end
    Cmd(cmd)
end

"""
Write TOML data (with sorted keys).
"""
function write_toml(file::String, data::Dict)
    open(file, "w") do io
        TOML.print(io, data, sorted=true)
    end
end
