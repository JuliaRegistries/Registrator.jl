module RegService

using Sockets
using Distributed
using Pkg
using Logging

import ..RegEdit: register
using ..Messaging

const config = Dict{String,Any}()

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
                haskey(config, "user") && (regp.gitconfig["user.name"] = config["user"])
                haskey(config, "email") && (regp.gitconfig["user.email"] = config["email"])
            end
            register(regp)
        end
        ret || return
    end
    nothing
end

function main()
    if isempty(ARGS)
        println("Usage: julia -e 'using Registrator; Registrator.RegService.main()' <configuration>")
        return
    end

    zsock = ReplySocket()

    merge!(config, Pkg.TOML.parsefile(ARGS[1])["regservice"])
    global_logger(SimpleLogger(stdout, get_log_level(config["log_level"])))

    @info("Starting registration service...")
    t = @async status_monitor(config["stop_file"], zsock)
    service(zsock)
    wait(t)

    # The !stopped! part is grep'ed by restart.sh, do not change
    @warn("Registration service !stopped!")
end

end    # module
