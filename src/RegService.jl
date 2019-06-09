module RegService

using Sockets
using Distributed
using Pkg
using Logging

import ..RegEdit: register
using ..Messaging

const CONFIG = Dict{String,Any}()

include("management.jl")

"""
    service(zsock::ReplySocket)
Start a server that calls `RegEdit.register` on incoming
registration requests from `zsock`. Registration requests
must be serialized `RegEdit.RegisterParams` objects. Close
the socket to halt the server.

Parameters:
- `zsock::ReplySocket`

Returns:
nothing
"""
function service(zsock::ReplySocket)
    while true
        ret = recvsend(zsock) do regp
            if isempty(regp.gitconfig)
                haskey(CONFIG, "user") && (regp.gitconfig["user.name"] = CONFIG["user"])
                haskey(CONFIG, "email") && (regp.gitconfig["user.email"] = CONFIG["email"])
            end
            register(regp)
        end
        ret || return
    end
    nothing
end

function main(config::AbstractString=isempty(ARGS) ? "config.toml" : first(ARGS))
    merge!(CONFIG, Pkg.TOML.parsefile(config)["regservice"])
    global_logger(SimpleLogger(stdout, get_log_level(CONFIG["log_level"])))
    zsock = ReplySocket(get(CONFIG, "port", 5555))

    @info("Starting registration service...")
    t = @async status_monitor(CONFIG["stop_file"], zsock)
    service(zsock)
    wait(t)

    # The !stopped! part is grep'ed by restart.sh, do not change
    @warn("Registration service !stopped!")
end

end    # module
