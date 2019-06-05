module CommentBot

using Sockets
using GitHub
using HTTP
using Distributed
using Base64
using Pkg
using Logging
using Dates
using JSON
using MbedTLS

import Pkg: TOML
import ..Registrator: post_on_slack_channel, pull_request_contents
import ..RegEdit: RegBranch, RegisterParams
import Base: string
using ..Messaging

include("trigger_types.jl")
include("parse_comment.jl")
include("github_utils.jl")
include("verify_projectfile.jl")
include("param_types.jl")
include("approval.jl")

include("../management.jl")

const event_queue = Channel{RequestParams}(1024)
const config = Dict{String,Any}()
const httpsock = Ref{Sockets.TCPServer}()

function print_entry_log(rp::RequestParams{PullRequestTrigger})
    @info "Creating registration pull request" reponame=rp.reponame prid=rp.trigger_src.prid
end

function print_entry_log(rp::RequestParams{CommitCommentTrigger})
    @info "Creating registration pull request" reponame=rp.reponame sha=get_comment_commit_id(rp.evt)
end

function print_entry_log(rp::RequestParams{IssueTrigger})
    @info "Creating registration pull request" reponame=rp.reponame branch=rp.trigger_src.branch
end

get_trigger_id(rp::RequestParams{PullRequestTrigger}) = rp.trigger_src.prid
get_trigger_id(rp::RequestParams{IssueTrigger}) = get_prid(rp.evt.payload)
get_trigger_id(rp::RequestParams{CommitCommentTrigger}) = get_comment_commit_id(rp.evt)

function make_pull_request(pp::ProcessedParams, rp::RequestParams, rbrn::RegBranch, target_registry::Dict{String,Any})
    name = rbrn.name
    ver = rbrn.version
    brn = rbrn.branch

    @info("Creating pull request name=$name, ver=$ver, branch=$brn")
    payload = rp.evt.payload
    creator = get_user_login(payload)
    reviewer = payload["sender"]["login"]
    @debug("Pull request creator=$creator, reviewer=$reviewer")

    trigger_id = get_trigger_id(rp)

    meta = JSON.json(Dict("request_type"=> string(rp),
                          "pkg_repo_name"=> rp.reponame,
                          "trigger_id"=> trigger_id,
                          "tree_sha"=> pp.tree_sha,
                          "version"=> string(ver)))
    key = config["enc_key"]
    enc_meta = "<!-- " * bytes2hex(encrypt(MbedTLS.CIPHER_AES_128_CBC, key, meta, key)) * " -->"
    params = Dict("base"=>target_registry["base_branch"],
                  "head"=>brn,
                  "maintainer_can_modify"=>true)
    ref = get_html_url(rp.evt.payload)

    params["title"], params["body"] = pull_request_contents(;
        registration_type=get(rbrn.metadata, "kind", ""),
        package=name,
        repo=string(rp.evt.repository.html_url),
        user="@$creator",
        version=ver,
        commit=pp.sha,
        release_notes=rp.release_notes,
        reviewer="@$reviewer",
        reference=ref,
        meta=enc_meta,
    )

    repo = join(split(target_registry["repo"], "/")[end-1:end], "/")
    pr, msg = create_or_find_pull_request(repo, params, rbrn)

    cbody = """
        Registration pull request $msg: [$(repo)/$(pr.number)]($(pr.html_url))

        After the above pull request is merged, it is recommended that a tag is created on this repository for the registered package version.

        This will be done automatically if [Julia TagBot](https://github.com/apps/julia-tagbot) is installed, or can be done manually through the github interface, or via:
        ```
        git tag -a v$(string(ver)) -m "<description of version>" $(pp.sha)
        git push origin v$(string(ver))
        ```
        """

    if get(rbrn.metadata, "warning", nothing) !== nothing
        cbody *= """
            Also, note the warning: $(rbrn.metadata["warning"])
            This can be safely ignored. However, if you want to fix this you can do so. Call register() again after making the fix. This will update the Pull request.
            """
    end

    @debug(cbody)
    make_comment(rp.evt, cbody)
    return pr
end

string(::RequestParams{PullRequestTrigger}) = "pull_request"
string(::RequestParams{CommitCommentTrigger}) = "commit_comment"
string(::RequestParams{IssueTrigger}) = "issue"

function action(rp::RequestParams{T}, zsock::RequestSocket) where T <: RegisterTrigger
    if rp.target === nothing
        target_registry_name, target_registry = first(config["targets"])
    else
        filteredtargets = filter(x->(x[1]==rp.target), config["targets"])
        if length(filteredtargets) == 0
            msg = "Error: target $(rp.target) not found"
            @debug(msg)
            make_comment(rp.evt, msg)
            set_error_status(rp)
            return
        else
            target_registry_name, target_registry = filteredtargets[1]
        end
    end

    pp = ProcessedParams(rp)
    @info("Processing register event", reponame=rp.reponame, target_registry_name)
    try
        if pp.cparams.isvalid && pp.cparams.error === nothing
            regp = RegisterParams(pp.cloneurl,
                                  Pkg.Types.read_project(copy(IOBuffer(pp.projectfile_contents))),
                                  pp.tree_sha;
                                  registry=target_registry["repo"],
                                  registry_deps=get(config, "registry_deps", String[]),
                                  push=true,
                                  )
            rbrn = sendrecv(zsock, regp; nretry=10)

            if rbrn === nothing || get(rbrn.metadata, "error", nothing) !== nothing
                if rbrn === nothing
                    msg = "ERROR: Registrator backend service unreachable"
                else
                    msg = "Error while trying to register: $(rbrn.metadata["error"])"
                end
                @debug(msg)
                make_comment(rp.evt, msg)
                set_error_status(rp)
            else
                make_pull_request(pp, rp, rbrn, target_registry)
                set_success_status(rp)
            end
        elseif pp.cparams.error !== nothing
            @info("Error while processing event: $(pp.cparams.error)")
            if pp.cparams.report_error
                msg = "Error while trying to register: $(pp.cparams.error)"
                @debug(msg)
                make_comment(rp.evt, msg)
            end
            set_error_status(rp)
        end
    catch ex
        bt = get_backtrace(ex)
        @info("Unexpected error: $bt")
        raise_issue(rp.evt, rp.phrase, bt)
    end
    @info("Done processing register event", reponame=rp.reponame, target_registry_name)
    nothing
end

function comment_handler(event::WebhookEvent, phrase::RegexMatch)
    @debug("Received event for $(event.repository.full_name), phrase: $phrase")
    try
        rp = RequestParams(event, phrase)
        isa(rp.trigger_src, EmptyTrigger) && rp.cparams.error === nothing && return

        if rp.cparams.isvalid && rp.cparams.error === nothing
            print_entry_log(rp)
            put!(event_queue, rp)
            set_pending_status(rp)
        elseif rp.cparams.error !== nothing
            @info("Error while processing event: $(rp.cparams.error)")
            if rp.cparams.report_error
                msg = "Error while trying to register: $(rp.cparams.error)"
                @debug(msg)
                make_comment(event, msg)
            end
            set_error_status(rp)
        end
    catch ex
        bt = get_backtrace(ex)
        @info("Unexpected error: $bt")
        raise_issue(event, phrase, bt)
    end

    return HTTP.Messages.Response(200)
end

function github_webhook(http_ip=config["http_ip"],
                        http_port=get(config, "http_port", parse(Int, get(ENV, "PORT", "8001"))))
    auth = get_jwt_auth()
    trigger = Regex(config["trigger"] * "(.*)")
    listener = GitHub.CommentListener(comment_handler, trigger; check_collab=false, auth=auth, secret=config["github"]["secret"])
    httpsock[] = Sockets.listen(IPv4(http_ip), http_port)

    do_action() = GitHub.run(listener, httpsock[], IPv4(http_ip), http_port)
    handle_exception(ex) = (isa(ex, Base.IOError) && (ex.code == -103)) ? :exit : :continue
    keep_running() = isopen(httpsock[])
    @info("GitHub webhook starting...", trigger, http_ip, http_port)
    recover("github_webhook", keep_running, do_action, handle_exception)
end

function request_processor(zsock::RequestSocket)
    do_action() = action(take!(event_queue), zsock)
    handle_exception(ex) = (isa(ex, InvalidStateException) && (ex.state == :closed)) ? :exit : :continue
    keep_running() = isopen(httpsock[])
    recover("request_processor", keep_running, do_action, handle_exception)
end

function main(config::AbstractString=isempty(ARGS) ? "config.toml" : first(ARGS))
    merge!(config, Pkg.TOML.parsefile(config)["commentbot"])
    global_logger(SimpleLogger(stdout, get_log_level(config["log_level"])))
    zsock = RequestSocket(get(config, "backend_port", 5555))

    @info("Starting server...")
    t1 = @async request_processor(zsock)
    t2 = @async status_monitor(config["stop_file"], event_queue, httpsock)
    github_webhook()
    wait(t1)
    wait(t2)

    # The !stopped! part is grep'ed by restart.sh, do not change
    @warn("Server !stopped!")
end

end    # module
