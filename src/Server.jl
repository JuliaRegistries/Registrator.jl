module RegServer

using Sockets
using GitHub
using HTTP
using Distributed
using Base64
using Pkg
using Logging

import Pkg: TOML
import ..Registrator: register, RegBranch, post_on_slack_channel

struct CommonParams
    isvalid::Bool
    error::Union{Nothing, String}
    report_error::Bool
end

struct RegParams
    evt::WebhookEvent
    phrase::RegexMatch
    reponame::String
    ispr::Bool
    iscc::Bool
    prid::Union{Nothing, Int}
    branch::Union{Nothing, String}
    comment_by_collaborator::Bool
    cparams::CommonParams

    function RegParams(evt::WebhookEvent, phrase::RegexMatch)
        reponame = evt.repository.full_name
        ispr = false
        iscc = false
        prid = nothing
        brn = nothing
        comment_by_collaborator = false
        err = nothing
        report_error = false

        if endswith(reponame, ".jl")
            comment_by_collaborator = is_comment_by_collaborator(evt)
            if comment_by_collaborator
                @debug("Comment is by collaborator")
                if is_pull_request(evt.payload)
                    @debug("Comment is on a pull request")
                    ispr = true
                    prid = get_prid(evt.payload)
                elseif is_commit_comment(evt.payload)
                    @debug("Comment is on a commit")
                    iscc = true
                else
                    @debug("Comment is on an issue")
                    brn = "master"
                    arg_regx = r"\((.*?)\)"
                    m = match(arg_regx, phrase.match)
                    if length(m.captures) != 0
                        arg = strip(m.captures[1])
                        if length(arg) != 0
                            @debug("Found branch arguement in comment: $arg")
                            brn = arg
                        end
                    end
                end
            else
                err = "Comment not made by collaborator"
                @debug(err)
            end
        else
            err = "Package name does not end with '.jl'"
            @debug(err)
            report_error = true
        end

        isvalid = comment_by_collaborator
        @debug("Event pre-check validity: $isvalid")

        return new(evt, phrase, reponame, ispr, iscc,
                   prid, brn, comment_by_collaborator,
                   CommonParams(isvalid, err, report_error))
    end
end

struct ProcessedParams
    projectfile_contents::Union{Nothing, String}
    projectfile_found::Bool
    projectfile_valid::Bool
    sha::Union{Nothing, String}
    tree_sha::Union{Nothing, String}
    cloneurl::Union{Nothing, String}
    cparams::CommonParams

    function ProcessedParams(rp::RegParams)
        if rp.cparams.error != nothing
            @debug("Pre-check failed, not processing RegParams: $(rp.cparams.error)")
            return ProcessedParams(nothing, nothing, copy(rp.cparams))
        end

        projectfile_contents = nothing
        projectfile_found = false
        projectfile_valid = false
        sha = nothing
        tree_sha = nothing
        cloneurl = nothing
        err = nothing
        report_error = true

        is_private = rp.evt.payload["repository"]["private"]
        if is_private
            auth = get_access_token(rp.evt)
        else
            auth = GitHub.AnonymousAuth()
        end

        if rp.ispr
            pr = pull_request(rp.reponame, rp.prid; auth=auth)
            cloneurl = pr.head.repo.html_url.uri * ".git"
            sha = pr.head.sha
            # @debug("Getting PR files repo=$(rp.reponame), prid=$(rp.prid)")
            # prfiles = pull_request_files(rp.reponame, rp.prid; auth=auth)

            # for f in prfiles
            #     if f.filename == "Project.toml"
            #         @debug("Project file found")
            #         projectfile_found = true

            #         ref = split(HTTP.URI(f.contents_url).query, "=")[2]

            #         @debug("Getting project file details")
            #         file_obj = file(rp.reponame, "Project.toml";
            #                         params=Dict("ref"=>ref), auth=auth)

            #         @debug("Getting project file contents")
            #         projectfile_contents = HTTP.get(file_obj.download_url).body |> copy |> String

            #         @debug("Checking project file validity")
            #         projectfile_valid, err = is_pfile_valid(projectfile_contents)

            #         break
            #     end
            # end

            # if !projectfile_found
            #     err = "Project file not found on this Pull request"
            #     @debug(err)
            # end
        elseif rp.iscc
            cloneurl = get_clone_url(rp.evt)
            sha = get_comment_commit_id(rp.evt)
        else
            cloneurl = get_clone_url(rp.evt)
            @debug("Getting sha from branch reponame=$(rp.reponame) branch=$(rp.branch)")
            sha, err = get_sha_from_branch(rp.reponame, rp.branch; auth=auth)
            @debug("Got sha=$(repr(sha)) error=$(repr(err))")
        end

        if err == nothing && sha != nothing
            projectfile_contents, tree_sha, projectfile_found, projectfile_valid, err = verify_projectfile_from_sha(rp.reponame, sha; auth = auth)
            if !projectfile_found
                err = "Project file not found on branch `$(rp.branch)`"
                @debug(err)
            end
        end

        isvalid = rp.comment_by_collaborator && projectfile_found && projectfile_valid
        @debug("Event validity: $(isvalid)")

        new(projectfile_contents, projectfile_found, projectfile_valid, sha, tree_sha, cloneurl,
            CommonParams(isvalid, err, report_error))
    end
end

const event_queue = Channel{RegParams}(1024)
const config = Dict{String,Any}()
const httpsock = Ref{Sockets.TCPServer}()

function get_access_token(event)
    create_access_token(Installation(event.payload["installation"]), get_jwt_auth())
end

function get_sha_from_branch(reponame, brn; auth = GitHub.AnonymousAuth())
    try
        b = branch(reponame, Branch(brn); auth=auth)
        sha = b.sha != nothing ? b.sha : b.commit.sha
        return sha, nothing
    catch ex
        d = parse_github_exception(ex)
        if d["Status Code"] == "404" && d["Message"] == "Branch not found"
            return nothing, "Branch `$brn` not found"
        else
            rethrow(ex)
        end
    end

    return nothing, nothing
end

function is_comment_by_collaborator(event)
    @debug("Checking if comment is by collaborator")
    user = get_user_login(event.payload)
    return iscollaborator(event.repository, user; auth=get_access_token(event))
end

function is_pull_request(payload)
    haskey(payload, "pull_request") || haskey(payload, "issue") && haskey(payload["issue"], "pull_request")
end

function is_commit_comment(payload)
    haskey(payload, "comment") && !haskey(payload, "issue")
end

function get_prid(payload)
    if haskey(payload, "pull_request")
        return payload["pull_request"]["number"]
    elseif haskey(payload, "issue")
        return payload["issue"]["number"]
    else
        error("Don't know how to get pull request number")
    end
end

function get_comment_commit_id(event)
    event.payload["comment"]["commit_id"]
end

function get_clone_url(event)
    event.payload["repository"]["clone_url"]
end


function is_pfile_parseable(c::String)
    @debug("Checking whether Project.toml is non-empty and parseable")
    if length(c) != 0
        try
            TOML.parse(c)
            return true, nothing
        catch ex
            if isa(ex, CompositeException) && isa(ex.exceptions[1], TOML.ParserError)
                err = "Error parsing project file"
                @debug(err)
                return false, err
            else
                rethrow(ex)
            end
        end
    else
        err = "Project file is empty"
        @debug(err)
        return false, err
    end
end

function is_pfile_nuv(c)
    @debug("Checking whether Project.toml contains name, uuid and version")
    ib = IOBuffer(c)

    try
        p = Pkg.Types.read_project(copy(ib))
        if p.name === nothing || p.uuid === nothing || p.version === nothing
            err = "Project file should contain name, uuid and version"
            @debug(err)
            return false, err
        end
    catch ex
        if isa(ex, ArgumentError)
            err = "Error reading Project.toml: $(ex.msg)"
            @debug(err)
            return false, err
        else
            rethrow(ex)
        end
    end

    return true, nothing
end

function is_pfile_valid(c::String)
    for f in [is_pfile_parseable, is_pfile_nuv]
        v, err = f(c)
        v || return v, err
    end
    return true, nothing
end

function verify_projectfile_from_sha(reponame, sha; auth=GitHub.AnonymousAuth())
    projectfile_contents = nothing
    projectfile_found = false
    projectfile_valid = false
    err = nothing
    @debug("Getting gitcommit object for sha")
    gcom = gitcommit(reponame, GitCommit(Dict("sha"=>sha)); auth=auth)
    @debug("Getting tree object for sha")
    t = tree(reponame, Tree(gcom.tree); auth=auth)

    for tr in t.tree
        if tr["path"] == "Project.toml"
            projectfile_found = true
            @debug("Project file found")

            @debug("Getting projectfile blob")
            if isa(auth, GitHub.AnonymousAuth)
                a = GitHub.authenticate(config["github"]["token"])
            else
                a = auth
            end
            b = blob(reponame, Blob(tr["sha"]); auth=a)

            @debug("Decoding base64 projectfile contents")
            projectfile_contents = join([String(copy(base64decode(k))) for k in split(b.content)])

            @debug("Checking project file validity")
            projectfile_valid, err = is_pfile_valid(projectfile_contents)
            break
        end
    end

    return projectfile_contents, t.sha, projectfile_found, projectfile_valid, err
end

function get_backtrace(ex)
    v = IOBuffer()
    Base.showerror(v, ex, catch_backtrace())
    return v.data |> copy |> String
end

function get_jwt_auth()
    GitHub.JWTAuth(config["github"]["app_id"], config["github"]["priv_pem"])
end

function make_comment(evt::WebhookEvent, body::String)
    config["registrator"]["reply_comment"] || return
    @debug("Posting comment to PR/issue")
    headers = Dict("private_token" => config["github"]["token"])
    params = Dict("body" => body)
    repo = evt.repository
    auth = get_access_token(evt)
    if is_commit_comment(evt.payload)
        GitHub.create_comment(repo, get_comment_commit_id(evt),
                              :commit; headers=headers,
                              params=params, auth=auth)
    else
        GitHub.create_comment(repo, get_prid(evt.payload),
                              :issue; headers=headers,
                              params=params, auth=auth)
    end
end

function get_html_url(payload)
    if haskey(payload, "pull_request")
        return payload["pull_request"]["html_url"]
    elseif haskey(payload, "issue")
        if haskey(payload, "comment")
            return payload["comment"]["html_url"]
        else
            return payload["issue"]["html_url"]
        end
    elseif haskey(payload, "comment")
        return payload["comment"]["html_url"]
    else
        error("Don't know how to get html_url")
    end
end

function raise_issue(event, phrase, bt)
    repo = event.repository.full_name
    lab = is_commit_comment(event.payload) ? get_comment_commit_id(event) : get_prid(event.payload)
    title = "Error registering $repo#$lab"
    input_phrase = "`[" * phrase.match[2:end-1] * "]`"
    body = """
Repository: $repo
Issue/PR: [$lab]($(get_html_url(event.payload)))
Command: $(input_phrase)
Stacktrace:

```
$bt
```
"""

    slack_config = get(config, "slack", nothing)
    if (slack_config !== nothing) && get(slack_config, "alert", false)
        post_on_slack_channel(body, slack_config["token"], slack_config["channel"])
    end

    if config["registrator"]["report_issue"]
        params = Dict("title"=>title, "body"=>body)
        regrepo = config["registrator"]["issue_repo"]
        iss = create_issue(regrepo; params=params, auth=GitHub.authenticate(config["github"]["token"]))
        msg = "Unexpected error occured during registration, see issue: [$(regrepo)#$(iss.number)]($(iss.html_url))"
        @debug(msg)
        make_comment(event, msg)
    else
        msg = "An unexpected error occured during registration."
        @debug(msg)
        make_comment(event, msg)
    end
end

function comment_handler(event::WebhookEvent, phrase::RegexMatch)
    global event_queue

    @debug("Received event for $(event.repository.full_name), phrase: $phrase")
    try
        handle_comment_event(event, phrase)
    catch ex
        bt = get_backtrace(ex)
        @info("Unexpected error: $bt")
        raise_issue(event, phrase, bt)
    end

    return HTTP.Messages.Response(200)
end

function set_status(rp, state, desc)
     config["registrator"]["set_status"] || return
     repo = rp.reponame
     kind = rp.evt.kind
     payload = rp.evt.payload
     if kind == "pull_request"
         commit = payload["pull_request"]["head"]["sha"]
         params = Dict("state" => state,
                       "context" => config["github"]["user"],
                       "description" => desc)
         GitHub.create_status(repo, commit;
                              auth=get_access_token(rp.evt),
                              params=params)
     end
end

set_pending_status(rp) = set_status(rp, "pending", "Processing request...")
set_error_status(rp) = set_status(rp, "error", "Failed to register")
set_success_status(rp) = set_status(rp, "success", "Done")

function handle_comment_event(event::WebhookEvent, phrase::RegexMatch)
    rp = RegParams(event, phrase)

    if rp.cparams.isvalid && rp.cparams.error == nothing
        if rp.ispr
            @info("Creating registration pull request for $(rp.reponame) PR: $(rp.prid)")
        elseif rp.iscc
            @info("Creating registration pull request for $(rp.reponame) sha: `$(get_comment_commit_id(rp.evt))`")
        else
            @info("Creating registration pull request for $(rp.reponame) branch: `$(rp.branch)`")
        end

        push!(event_queue, rp)
        set_pending_status(rp)
    elseif rp.cparams.error != nothing
        @info("Error while processing event: $(rp.cparams.error)")
        if rp.cparams.report_error
            msg = "Error while trying to register: $(rp.cparams.error)"
            @debug(msg)
            make_comment(event, msg)
        end
        set_error_status(rp)
    end
end

function parse_github_exception(ex::ErrorException)
    msgs = map(strip, split(ex.msg, '\n'))
    d = Dict()
    for m in msgs
        a, b = split(m, ":"; limit=2)
        d[a] = strip(b)
    end
    return d
end

function is_pr_exists_exception(ex)
    d = parse_github_exception(ex)

    if d["Status Code"] == "422" &&
       match(r"A pull request already exists", d["Errors"]) != nothing
        return true
    end

    return false
end

function get_user_login(payload)
    if haskey(payload, "comment")
        return payload["comment"]["user"]["login"]
    elseif haskey(payload, "issue")
        return payload["issue"]["user"]["login"]
    elseif haskey(payload, "pull_request")
        return payload["pull_request"]["user"]["login"]
    else
        error("Don't know how to get user login")
    end
end

function make_pull_request(pp::ProcessedParams, rp::RegParams, rbrn::RegBranch, target_registry::Dict{String,Any})
    name = rbrn.name
    ver = rbrn.version
    brn = rbrn.branch

    @info("Creating pull request name=$name, ver=$ver, branch=$brn")
    payload = rp.evt.payload
    creator = get_user_login(payload)
    reviewer = payload["sender"]["login"]
    @debug("Pull request creator=$creator, reviewer=$reviewer")

    params = Dict("title"=>"Register $name: $ver",
                  "base"=>target_registry["base_branch"],
                  "head"=>brn,
                  "maintainer_can_modify"=>true)

    params["body"] = """Register $name: $ver
cc: @$(creator)
reviewer: @$(reviewer)"""

    pr = nothing
    repo = join(split(target_registry["repo"], "/")[end-1:end], "/")
    try
        pr = create_pull_request(repo; auth=GitHub.authenticate(config["github"]["token"]), params=params)
        @debug("Pull request created")
    catch ex
        if is_pr_exists_exception(ex)
            @debug("Pull request already exists, not creating")
        else
            rethrow(ex)
        end
    end

    msg = "created"

    if pr == nothing
        @debug("Searching for existing PR")
        for p in pull_requests(repo; auth=GitHub.authenticate(config["github"]["token"]))[1]
            if p.base.ref == target_registry["base_branch"] && p.head.ref == brn
                @debug("PR found")
                pr = p
                break
            end
        end
        msg = "updated"
    end

    if pr == nothing
        error("Existing PR not found")
    end

    cbody = "Registration pull request $msg: [$(repo)/$(pr.number)]($(pr.html_url))"
    @debug(cbody)
    make_comment(rp.evt, cbody)
end

function handle_register_events(rp::RegParams)
    for (target_registry_name,target_registry) in config["targets"]
        @info("Processing register event", reponame=rp.reponame, target_registry_name)
        try
            handle_register(rp, target_registry)
        catch ex
            bt = get_backtrace(ex)
            @info("Unexpected error: $bt")
            raise_issue(rp.evt, rp.phrase, bt)
        end
        @info("Done processing register event", reponame=rp.reponame, target_registry_name)
    end
end

function handle_register(rp::RegParams, target_registry::Dict{String,Any})
    pp = ProcessedParams(rp)

    if pp.cparams.isvalid && pp.cparams.error == nothing
        rbrn = register(pp.cloneurl, Pkg.Types.read_project(copy(IOBuffer(pp.projectfile_contents))),
                        pp.tree_sha; registry=target_registry["repo"], push=true)
        if rbrn.error !== nothing
            msg = "Error while trying to register: $(rbrn.error)"
            @debug(msg)
            make_comment(rp.evt, msg)
            set_error_status(rp)
        else
            make_pull_request(pp, rp, rbrn, target_registry)
            set_success_status(rp)
        end
    elseif pp.cparams.error != nothing
        @info("Error while processing event: $(pp.cparams.error)")
        if pp.cparams.report_error
            msg = "Error while trying to register: $(pp.cparams.error)"
            @debug(msg)
            make_comment(rp.evt, msg)
        end
        set_error_status(rp)
    end
end

function get_log_level()
    log_level_str = lowercase(config["server"]["log_level"])

    (log_level_str == "debug") ? Logging.Debug :
    (log_level_str == "info")  ? Logging.Info  :
    (log_level_str == "warn")  ? Logging.Warn  : Logging.Error
end

function status_monitor()
    stop_file = config["server"]["stop_file"]
    while isopen(event_queue)
        sleep(5)
        flush(stdout); flush(stderr);
        # stop server if stop is requested
        if isfile(stop_file)
            @warn("Server stop requested.")
            flush(stdout); flush(stderr)

            # stop accepting new requests
            close(httpsock[])

            # wait for queued requests to be processed and close queue
            while isready(event_queue)
                yield()
            end
            close(event_queue)
            rm(stop_file; force=true)
        end
    end
end

function recover(name, keep_running, do_action, handle_exception; backoff=0, backoffmax=120, backoffincrement=1)
    while keep_running()
        try
            do_action()
            backoff = 0
        catch ex
            exception_action = handle_exception(ex)
            if exception_action == :exit
                @warn("Stopping", name)
                return
            else # exception_action == :continue
                bt = get_backtrace(ex)
                @error("Recovering from unknown exception", name, ex, bt, backoff)
                sleep(backoff)
                backoff = min(backoffmax, backoff+backoffincrement)
            end
        end
    end
end

function request_processor()
    do_action() = handle_register_events(take!(event_queue))
    handle_exception(ex) = (isa(ex, InvalidStateException) && (ex.state == :closed)) ? :exit : :continue
    keep_running() = isopen(event_queue)
    recover("request_processor", keep_running, do_action, handle_exception)
end

function github_webhook(http_ip=config["server"]["http_ip"], http_port=config["server"]["http_port"])
    auth = get_jwt_auth()
    trigger = Regex("`$(config["registrator"]["trigger"])(.*?)`")
    listener = GitHub.CommentListener(comment_handler, trigger; check_collab=false, auth=auth, secret=config["github"]["secret"])
    httpsock[] = Sockets.listen(IPv4(http_ip), http_port)

    do_action() = GitHub.run(listener, httpsock[], IPv4(http_ip), http_port)
    handle_exception(ex) = (isa(ex, Base.IOError) && (ex.code == -103)) ? :exit : :continue
    keep_running() = isopen(httpsock[])
    @info("GitHub webhook starting...", trigger, http_ip, http_port)
    recover("github_webhook", keep_running, do_action, handle_exception)
end

function main()
    if isempty(ARGS)
        println("Usage: julia -e 'using Registrator; Registrator.RegServer.main()' <configuration>")
        return
    end

    merge!(config, Pkg.TOML.parsefile(ARGS[1]))
    global_logger(SimpleLogger(stdout, get_log_level()))

    @info("Starting server...")
    t1 = @async request_processor()
    t2 = @async status_monitor()
    github_webhook()
    wait(t1)
    wait(t2)
    @warn("Server stopped.")
end

end    # module
