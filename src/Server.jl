module RegServer

using Sockets
using GitHub
using HTTP
using Distributed

import ..Registrator: register

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

function is_projectfile_edited(event)
    repo = get_reponame(event)
    prid = get_prid(event)
    prfiles = pull_request_files(repo, prid)
    "Project.toml" in [f.filename for f in prfiles]
end

mutable struct RegParams
    evt::WebhookEvent
    reponame::String
    cloneurl::String
    ispr::Bool
    prid::Union{Nothing, Int}
    sha::Union{Nothing, String}
    branch::Union{Nothing, String}
    comment_by_collaborator::Bool
    projectfile_found::Bool
    isvalid::Bool
    error::Union{Nothing, String}
    report_error::Bool

    function RegParams(evt::WebhookEvent, phrase::RegexMatch)
        reponame = evt.repository.full_name
        cloneurl = evt.payload["repository"]["clone_url"]
        ispr = true
        prid = nothing
        sha = nothing
        brn = nothing
        comment_by_collaborator = is_comment_by_collaborator(evt)
        error = nothing
        report_error = true

        if comment_by_collaborator
            @debug("Comment is by collaborator")
            if haskey(evt.payload["issue"], "pull_request")
                @debug("Comment is on a pull request")
                prid = evt.payload["issue"]["number"]
                pr = pull_request(reponame, prid)
                sha = pr.head.sha
                @debug("Getting PR files repo=$reponame, prid=$prid")
                prfiles = pull_request_files(reponame, prid)
                projectfile_found = "Project.toml" in [f.filename for f in prfiles]
                @debug("Project file is $(projectfile_found ? "found" : "not found")")

                if !projectfile_found
                    error = "Project file not found on this Pull request"
                end
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

                @debug("Gettig sha from branch")
                sha, error = get_sha_from_branch(reponame, brn)
                @debug("Got sha=$sha error=$error")

                if error == nothing && sha != nothing
                    @debug("Getting gitcommit object for sha")
                    gcom = gitcommit(reponame, GitCommit(Dict("sha"=>sha)))
                    @debug("Getting tree object for sha")
                    t = tree(reponame, Tree(gcom.tree))

                    for tr in t.tree
                        if tr["path"] == "Project.toml"
                            projectfile_found = true
                            break
                        end
                    end

                    @debug("Project file is $(projectfile_found ? "found" : "not found")")
                    if !projectfile_found
                        error = "Project file not found on branch `$brn`"
                    end
                end
            end
        else
            error = "Comment not made by collaborator"
            @debug("$error")
            report_error = false
        end

        isvalid = comment_by_collaborator && projectfile_found
        @debug("Event validity: $isvalid")

        return new(evt, reponame, cloneurl, ispr, prid, sha, brn,
                  comment_by_collaborator, projectfile_found,
                  isvalid, error, report_error)
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

"""Start a github webhook listener to process events"""
function start_github_webhook(http_ip=DEFAULT_HTTP_IP, http_port=DEFAULT_HTTP_PORT)
    auth = get_jwt_auth()
    listener = GitHub.CommentListener(comment_handler, TRIGGER; check_collab=false, auth=auth, secret=GITHUB_SECRET)
    GitHub.run(listener, IPv4(http_ip), http_port)
end

function get_commit(event::WebhookEvent)
    @info("getting commit sha for event")
    kind = event.kind
    payload = event.payload
    commit = nothing
    if kind == "push"
        commit = payload["after"]
    elseif kind == "pull_request"
        commit = payload["pull_request"]["head"]["sha"]
    elseif kind == "status"
        commit = payload["commit"]["sha"]
    elseif kind == "pull_request_review"
        commit = payload["review"]["commit_id"]
    end
    commit
end

event_queue = Queue{RegParams}()

function make_comment(rp, body)
    @debug("Posting comment to PR/issue")
    headers = Dict("private_token" => GITHUB_TOKEN)
    params = Dict("body" => body)
    repo = rp.evt.repository
    GitHub.create_comment(repo, rp.evt.payload["issue"]["number"],
                          :issue; headers=headers,
                          params=params, auth=GitHub.authenticate(GITHUB_TOKEN))
end

function comment_handler(event::WebhookEvent, phrase)
    global event_queue

    @debug("Received event for $(event.repository.full_name), phrase: $phrase")
    rp = RegParams(event, phrase)

    if rp.isvalid && rp.error == nothing
        if rp.ispr
            @info("Creating registration pull request for $(rp.reponame) PR: $(rp.prid)")
        else
            @info("Creating registration pull request for $(rp.reponame) branch: `$(rp.branch)`")
        end

        enqueue!(event_queue, rp)

        if !DEV_MODE
            params = Dict("state" => "pending",
                          "context" => GITHUB_USER,
                          "description" => "pending")
            GitHub.create_status(repo, commit;
                                 auth=get_jwt_auth(),
                                 params=params)
        end
    else
        @info("Error while processing event: $(rp.error)")
        if rp.report_error
            make_comment(event, "Error while trying to register: $(rp.error)")
        end
    end

    return HTTP.Messages.Response(200)
end

#=
function comment_handler(event::WebhookEvent, phrase)
    global event_queue
    kind, payload, repo = event.kind, event.payload, event.repository

    if kind == "pull_request_review" &&
       payload["action"] == "submitted" &&
       is_approved_by_collaborator(event) &&
       is_projectfile_edited(event)

        @info("Creating registration pull request for $(get_reponame(event)) PR: $(get_prid(event))")
        enqueue!(event_queue, (event, :register))

    elseif kind == "ping"

        @info("Received event $kind, nothing to do")
        return HTTP.Messages.Response(200)

    elseif DO_CI && kind in ["pull_request", "push"] &&
       payload["action"] in ["opened", "reopened", "synchronize"]

        commit = get_commit(event)
        @info("Enqueueing CI for $commit")
        enqueue!(event_queue, (event, :ci))

        if !DEV_MODE
            params = Dict("state" => "pending",
                          "context" => GITHUB_USER,
                          "description" => "pending")
            GitHub.create_status(repo, commit;
                                 auth=get_jwt_auth(),
                                 params=params)
        end
    end

    return HTTP.Messages.Response(200)
end
=#

function get_prid(event)
    if haskey(event.payload, "pull_request")
        event.payload["pull_request"]["number"]
    else
        event.payload["issue"]["number"]
    end
end

get_reponame(event) = event.repository.full_name

is_pr_open(repo::String, prid::Int) =
    get(pull_request(Repo(repo), prid; auth=get_jwt_auth()).state) == "open"

is_pr_open(event::WebhookEvent) =
    is_pr_open(get_reponame(event), get_prid(event))

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

function handle_ci_events(event)
    commit = get_commit(event)

    if !is_pr_open(event)
        @info("PR closed ignoring CI")
        return
    end

    @info("Processing CI event for commit: $commit")

    # DO CI HERE

    # CI results
    text_table = ""
    success = false

    if !DEV_MODE
        headers = Dict("private_token" => get_jwt_auth())
        params = Dict("body" => text_table)
        repo = event.repository
        auth = get_jwt_auth()
        GitHub.create_comment(repo, event.payload["pull_request"]["number"],
                              :issue; headers=headers,
                              params=params, auth=auth)

        params = Dict("state" => success ? "success" : "error",
                      "context" => GITHUB_USER,
                      "description" => "done")
        GitHub.create_status(repo, commit;
                             auth=auth,
                             params=params)
    else
        println(text_table)
    end

    @info("Done processing event for commit: $commit")
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

function make_pull_request(rp, name, ver, brn)
    @info("Creating pull request name=$name, ver=$ver, branch=$brn")
    creator = rp.evt.payload["issue"]["user"]["login"]
    reviewer = rp.evt.payload["sender"]["login"]
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
    make_comment(rp, cbody)
end

function get_clone_url(event)
    event.payload["repository"]["clone_url"]
end

function handle_register_events(rp::RegParams)
    @info("Processing Register event for $(rp.reponame) $(rp.sha)")

    name, ver, brn = register(rp.cloneurl, rp.sha; registry=REGISTRY, push=true)
    make_pull_request(rp, name, ver, brn)

    @info("Done processing event for $(rp.reponame) $(rp.sha)")
end

function tester()
    global event_queue

    while true
        while !isempty(event_queue)
            rp = dequeue!(event_queue)
            handle_register_events(rp)
        end

        sleep(CYCLE_INTERVAL)
    end
end

function main()
    @async @recover tester()
    @recover start_github_webhook()
end

end    # module
