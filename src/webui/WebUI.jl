module WebUI

using ..Registrator: RegEdit, pull_request_contents

using Base64
using Dates
using GitForge, GitForge.GitHub, GitForge.GitLab
using HTTP
using JSON
using Mux
using Pkg, Pkg.TOML
using Sockets
using TimeToLive
using Logging
using Mustache

using ..Messaging

const ROUTES = Dict(
    :INDEX => "/",
    :AUTH => "/auth",
    :CALLBACK => "/callback",
    :SELECT => "/select",
    :REGISTER => "/register",
    :STATUS => "/status",
)

const DOCS = "https://github.com/JuliaRegistries/Registrator.jl/blob/master/README.web.md#usage-for-package-maintainers"
const CONFIG = Dict{String, Any}()

include("../management.jl")
const httpsock = Ref{Sockets.TCPServer}()

include("providers.jl")

# The target registry.
struct Registry{F <: GitForge.Forge, R}
    forge::F
    repo::R
    url::String
    clone::String
    deps::Vector{String}
    enable_release_notes::Bool
end

# U is a User type, e.g. GitHub.User.
struct User{U, F <: GitForge.Forge}
    user::U
    forge::F
end

struct RegistrationData
    project::Pkg.Types.Project
    tree::String
    repo::Union{GitForge.GitHub.Repo, GitForge.GitLab.Project}
    user::Union{GitForge.GitHub.User, GitForge.GitLab.User}
    ref::String
    commit::String
    notes::String
end

const event_queue = Channel{RegistrationData}(1024)

struct RegistrationState
    msg::String
    state::Symbol
end

const PROVIDERS = Dict{String, Provider}()
const REGISTRY = Ref{Registry}()
const USERS = TTL{String, User}(Hour(1))
const REGISTRATIONS = Dict{String, RegistrationState}()

###########
# Helpers #
###########

include("webutils.jl")
include("gitutils.jl")

##########
# Routes #
##########

include("routes/index.jl")
include("routes/auth.jl")
include("routes/callback.jl")
include("routes/select.jl")
include("routes/register.jl")
include("routes/status.jl")

##############
# Entrypoint #
##############

function init_registry()
    url = CONFIG["registry_url"]
    k = get(CONFIG, "registry_provider") do
        if occursin("github", url)
            "github"
        elseif occursin("gitlab", url)
            "gitlab"
        end
    end
    haskey(PROVIDERS, k) || error("Unsupported registry host")
    forge = PROVIDERS[k].client
    owner, name = splitrepo(url)
    repo = @gf get_repo(forge, owner, name)
    repo === nothing && error("Registry lookup failed")
    clone = get(CONFIG, "registry_clone_url", url)
    deps = get(CONFIG, "registry_deps", String[])
    enable_release_notes = !get(CONFIG, "disable_release_notes", false)
    REGISTRY[] = Registry(forge, repo, url, clone, deps, enable_release_notes)
end

for f in [:index, :auth, :callback, :select, :register]
    @eval $f(func::Function, r::HTTP.Request) = func($f(r))
end

error_handler(f::Function, r::HTTP.Request) = try
    f(r)
catch e
    println(get_backtrace(e))
    @error "Handler error" route=r.target
    html(500, "Server error, sorry!")
end

pathmatch(p::AbstractString, f::Function) = branch(r -> first(split(r.target, "?")) == p, f)

function action(regdata::RegistrationData, zsock::RequestSocket)
    regp = RegEdit.RegisterParams(cloneurl(regdata.repo), regdata.project, regdata.tree;
        registry=REGISTRY[].clone, registry_deps=REGISTRY[].deps, push=true,
    )
    branch = sendrecv(zsock, regp; nretry=5)
    if branch === nothing || get(branch.metadata, "error", nothing) !== nothing
        if branch === nothing
            msg = "ERROR: Registrator backend service unreachable"
        else
            msg = "Registration failed: " * branch.metadata["error"]
        end
        state = :errored
    else
        title, body = pull_request_contents(;
            registration_type=get(branch.metadata, "kind", ""),
            package=regdata.project.name,
            repo=web_url(regdata.repo),
            user=display_user(regdata.user),
            gitref=regdata.ref,
            version=regdata.project.version,
            commit=regdata.commit,
            release_notes=regdata.notes,
        )

        # Make the PR.
        pr = @gf make_registration_request(REGISTRY[], branch.branch, title, body)
        if pr === nothing
            msg = "Registration failed: Making pull request failed"
            state = :errored
        else
            url = web_url(pr)
            msg = """Registry PR successfully created, see it <a href="$url" target="_blank">here</a>!"""
            state = :success
        end
    end
    @debug msg
    REGISTRATIONS[regdata.commit] = RegistrationState(msg, state)
end

function request_processor(zsock::RequestSocket)
    do_action() = action(take!(event_queue), zsock)
    handle_exception(ex) = ex isa InvalidStateException && ex.state === :closed ? :exit : :continue
    keep_running() = isopen(httpsock[])
    recover("request_processor", keep_running, do_action, handle_exception)
end

function start_server(ip::IPAddr, port::Int)
    httpsock[] = Sockets.listen(ip, port)
    @app server = (
        error_handler,
        pathmatch(ROUTES[:INDEX], index),
        pathmatch(ROUTES[:AUTH], auth),
        pathmatch(ROUTES[:CALLBACK], callback),
        pathmatch(ROUTES[:SELECT], select),
        pathmatch(ROUTES[:REGISTER], register),
        pathmatch(ROUTES[:STATUS], status),
        r -> html(404, "Page not found"),
    )
    do_action() = wait(serve(server, ip, port; server=httpsock[], readtimeout=0))
    handle_exception(ex) = ex isa Base.IOError && ex.code == -103 ? :exit : :continue
    keep_running() = isopen(httpsock[])
    recover("webui", keep_running, do_action, handle_exception)
end

function main(config::AbstractString=isempty(ARGS) ? "config.toml" : first(ARGS))
    merge!(CONFIG, TOML.parsefile(config)["web"])

    global_logger(SimpleLogger(stdout, get_log_level(get(CONFIG, "log_level", "INFO"))))
    zsock = RequestSocket(get(CONFIG, "backend_port", 5555))

    if haskey(CONFIG, "route_prefix")
        for (k, v) in ROUTES
            ROUTES[k] = CONFIG["route_prefix"] * v
        end
    end

    init_providers()
    init_registry()

    ip = CONFIG["ip"] == "localhost" ? Sockets.localhost : parse(IPAddr, CONFIG["ip"])
    port = CONFIG["port"]

    @info "Starting WebUI" ip port
    monitor = @async status_monitor(CONFIG["stop_file"], event_queue, httpsock)
    reqproc = @async request_processor(zsock)
    start_server(ip, port)
    wait(reqproc)
    wait(monitor)

    # The !stopped! part is grep'ed by restart.sh, do not change
    @info "Server !stopped!"
end

end
