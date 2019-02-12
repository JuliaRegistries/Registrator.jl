module RegServer

using Sockets
using GitHub
using HTTP
using Distributed

import ..Registrator: register, RegBranch

include("conf.jl")

function get_sha_from_branch(reponame, brn)
    try
        b = branch(reponame, Branch(brn))
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
    c = event.payload["comment"]
    user = c["user"]["login"]
    auth = get_jwt_auth()
    tok = create_access_token(Installation(event.payload["installation"]), auth)
    return iscollaborator(event.repository, user; auth=tok)
end

struct CommonParams
    isvalid::Bool
    error::Union{Nothing, String}
    report_error::Bool
end

struct RegParams
    evt::WebhookEvent
    reponame::String
    cloneurl::String
    ispr::Bool
    prid::Union{Nothing, Int}
    branch::Union{Nothing, String}
    comment_by_collaborator::Bool
    cparams::CommonParams

    function RegParams(evt::WebhookEvent, phrase::RegexMatch)
        reponame = evt.repository.full_name
        cloneurl = evt.payload["repository"]["clone_url"]
        ispr = true
        prid = nothing
        brn = nothing
        comment_by_collaborator = false
        error = nothing
        report_error = true

        if endswith(reponame, ".jl")
            comment_by_collaborator = is_comment_by_collaborator(evt)
            if comment_by_collaborator
                @debug("Comment is by collaborator")
                if haskey(evt.payload["issue"], "pull_request")
                    @debug("Comment is on a pull request")
                    prid = evt.payload["issue"]["number"]
                else
                    ispr = false
                    brn = "master"
                    arg_regx = r"\((.*?)\)"
                    m = match(arg_regx, phrase)
                    if length(m.captures) != 0
                        arg = strip(m.captures[1])
                        if length(arg) != 0
                            @debug("Found branch arguement in comment: $arg")
                            brn = arg
                        end
                    end
                end
            else
                error = "Comment not made by collaborator"
                @debug("$error")
                report_error = false
            end
        else
            error = "Package name does not end with '.jl'"
            @debug("$error")
        end

        isvalid = comment_by_collaborator
        @debug("Event pre-check validity: $isvalid")

        return new(evt, reponame, cloneurl, ispr, prid, brn,
                   comment_by_collaborator,
                   CommonParams(isvalid, error, report_error))
    end
end

struct ProcessedParams
    projectfile_found::Union{Nothing, Bool}
    sha::Union{Nothing, String}
    rparams::RegParams
    cparams::CommonParams

    function ProcessedParams(rp::RegParams)
        if rp.cparams.error != nothing
            @debug("Pre-check failed, not processing RegParams: $(rp.cparams.error)")
            return ProcessedParams(nothing, nothing, copy(rp.cparams))
        end

        projectfile_found = nothing
        sha = nothing
        error = nothing
        report_error = false

        if rp.ispr
            pr = pull_request(rp.reponame, rp.prid)
            sha = pr.head.sha
            @debug("Getting PR files repo=$(rp.reponame), prid=$(rp.prid)")
            prfiles = pull_request_files(rp.reponame, rp.prid)
            projectfile_found = "Project.toml" in [f.filename for f in prfiles]
            @debug("Project file is $(projectfile_found ? "found" : "not found")")

            if !projectfile_found
                error = "Project file not found on this Pull request"
            end
        else
            @debug("Gettig sha from branch")
            sha, error = get_sha_from_branch(rp.reponame, rp.brn)
            @debug("Got sha=$(sha) error=$(error)")

            if error == nothing && sha != nothing
                @debug("Getting gitcommit object for sha")
                gcom = gitcommit(rp.reponame, GitCommit(Dict("sha"=>sha)))
                @debug("Getting tree object for sha")
                t = tree(rp.reponame, Tree(gcom.tree))

                for tr in t.tree
                    if tr["path"] == "Project.toml"
                        projectfile_found = true
                        break
                    end
                end

                @debug("Project file is $(projectfile_found ? "found" : "not found")")
                if !projectfile_found
                    error = "Project file not found on branch `$(rp.brn)`"
                end
            end
        end

        isvalid = rp.comment_by_collaborator && projectfile_found
        @debug("Event validity: $(isvalid)")

        new(projectfile_found, sha, rp, CommonParams(isvalid, error, report_error))
    end
end

function get_backtrace(ex)
    v = IOBuffer()
    Base.showerror(v, ex, catch_backtrace())
    return v.data |> copy |> String
end

function get_jwt_auth()
    GitHub.JWTAuth(GITHUB_APP_ID, GITHUB_PRIV_PEM)
end

function start_github_webhook(http_ip=DEFAULT_HTTP_IP, http_port=DEFAULT_HTTP_PORT)
    auth = get_jwt_auth()
    listener = GitHub.CommentListener(comment_handler, TRIGGER; check_collab=false, auth=auth, secret=GITHUB_SECRET)
    GitHub.run(listener, IPv4(http_ip), http_port)
end

const event_queue = Vector{ProcessedParams}()

function make_comment(evt::WebhookEvent, body::String)
    @debug("Posting comment to PR/issue")
    headers = Dict("private_token" => GITHUB_TOKEN)
    params = Dict("body" => body)
    repo = evt.repository
    GitHub.create_comment(repo, evt.payload["issue"]["number"],
                          :issue; headers=headers,
                          params=params, auth=GitHub.authenticate(GITHUB_TOKEN))
end

function comment_handler(event::WebhookEvent, phrase)
    global event_queue

    @debug("Received event for $(event.repository.full_name), phrase: $phrase")
    rp = RegParams(event, phrase)

    if rp.cparams.isvalid && rp.cparams.error == nothing
        if rp.ispr
            @info("Creating registration pull request for $(rp.reponame) PR: $(rp.prid)")
        else
            @info("Creating registration pull request for $(rp.reponame) branch: `$(rp.branch)`")
        end

        push!(event_queue, ProcessedParams(rp))

        if !DEV_MODE
            params = Dict("state" => "pending",
                          "context" => GITHUB_USER,
                          "description" => "pending")
            GitHub.create_status(repo, commit;
                                 auth=get_jwt_auth(),
                                 params=params)
        end
    else
        @info("Error while processing event: $(rp.cparams.error)")
        if rp.cparams.report_error
            make_comment(event, "Error while trying to register: $(rp.cparams.error)")
        end
    end

    return HTTP.Messages.Response(200)
end

function recover(f)
    while true
        try
            f()
        catch ex
            @info("Task $f failed")
            @info(get_backtrace(ex))
        end

        sleep(CYCLE_INTERVAL)
    end
end

macro recover(e)
    :(recover(() -> $(esc(e)) ))
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

function make_pull_request(pp::ProcessedParams, rbrn::RegBranch)
    name = rbrn.name
    ver = rbrn.version
    brn = rbrn.branch

    @info("Creating pull request name=$name, ver=$ver, branch=$brn")
    payload = pp.rparams.evt.payload
    creator = payload["issue"]["user"]["login"]
    reviewer = payload["sender"]["login"]
    @debug("Pull request creator=$creator, reviewer=$reviewer")

    params = Dict("title"=>"Register $name: $ver",
                  "base"=>REGISTRY_BASE_BRANCH,
                  "head"=>brn,
                  "maintainer_can_modify"=>true)

    params["body"] = """Register $name: $ver
cc: @$(creator)
reviewer: @$(reviewer)"""

    pr = nothing
    repo = join(split(REGISTRY, "/")[end-1:end], "/")
    try
        pr = create_pull_request(repo; auth=GitHub.authenticate(GITHUB_TOKEN), params=params)
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
        for p in pull_requests(repo; auth=GitHub.authenticate(GITHUB_TOKEN))[1]
            if p.base.ref == REGISTRY_BASE_BRANCH && p.head.ref == brn
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
    make_comment(pp.rparams.evt, cbody)
end

function get_clone_url(event)
    event.payload["repository"]["clone_url"]
end

function handle_register_events(pp::ProcessedParams)
    @info("Processing Register event for $(pp.rparams.reponame) $(pp.sha)")

    rbrn = register(pp.rparams.cloneurl, pp.sha; registry=REGISTRY, push=true)
    make_pull_request(pp, rbrn)

    @info("Done processing event for $(pp.rparams.reponame) $(pp.sha)")
end

function tester()
    global event_queue

    while true
        while !isempty(event_queue)
            pp = popfirst!(event_queue)
            handle_register_events(pp)
        end

        sleep(CYCLE_INTERVAL)
    end
end

function main()
    @async @recover tester()
    @recover start_github_webhook()
end

end    # module
