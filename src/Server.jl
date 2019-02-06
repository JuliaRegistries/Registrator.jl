module RegServer

using Sockets
using GitHub
using DataStructures
using HTTP
using Distributed

import ..Registrator: register

include("conf.jl")

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
    listener = GitHub.CommentListener(comment_handler, TRIGGER; auth=auth, secret=GITHUB_SECRET)
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

event_queue = Queue{Tuple{WebhookEvent, Symbol}}()

function is_projectfile_edited(event)
    @info("Checking for project file in PR")
    repo = get_reponame(event)
    prid = get_prid(event)
    prfiles = pull_request_files(repo, prid)
    if "Project.toml" in [f.filename for f in prfiles]
        @info("Project file is edited")
        return true
    else
        @info("Project file is not edited")
        return false
    end
end

function is_comment_by_collaborator(event)
    @info("Checking whether comment is by collaborator")
    c = event.payload["comment"]
    user = c["user"]["login"]
    auth = get_jwt_auth()
    tok = create_access_token(Installation(event.payload["installation"]), auth)
    if iscollaborator(event.repository, user; auth=tok)
        @info("Comment made by collaborator")
        return true
    else
        @info("Comment not made by collaborator")
        return false
    end
end

function make_comment(event, body)
    auth = get_jwt_auth()
    headers = Dict("private_token" => auth)
    params = Dict("body" => body)
    repo = event.repository
    GitHub.create_comment(repo, event.payload["pull_request"]["number"],
                          :issue; headers=headers,
                          params=params, auth=auth)
end

function comment_handler(event::WebhookEvent, phrase)
    global event_queue
    kind, payload, repo = event.kind, event.payload, event.repository

    is_comment_by_collaborator(event)
    is_projectfile_edited(event)

    @info("Creating registration pull request for $(get_reponame(event)) PR: $(get_prid(event))")
    enqueue!(event_queue, (event, :register))

    if !DEV_MODE
        params = Dict("state" => "pending",
                      "context" => GITHUB_USER,
                      "description" => "pending")
        GitHub.create_status(repo, commit;
                             auth=get_jwt_auth(),
                             params=params)
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

function make_pull_request(event, name, ver, brn)
    @info("Creating pull request name=$name, ver=$ver, branch=$brn")
    creator = event.payload["issue"]["user"]["login"]
    reviewer = event.payload["sender"]["login"]
    @info("Pull request creator=$creator, reviewer=$reviewer")

    params = Dict("title"=>"Register $name: $ver",
                  "base"=>REGISTRY_BASE_BRANCH,
                  "head"=>brn,
                  "maintainer_can_modify"=>true)

    params["body"] = """Register $name: $ver
cc: @$(creator)
reviewer: @$(reviewer)"""

    try
        create_pull_request(get_reponame(event); auth=GitHub.authenticate(GITHUB_TOKEN), params=params)
        @info("Pull request created")
    catch ex
        if ex.resp.code == 422
            @info("Pull request already exists, not creating")
        else
            rethrow(ex)
        end
    end
end

function get_clone_url(event)
    event.payload["repository"]["clone_url"]
end

function handle_register_events(event)
    commit = get_commit(event)

    @info("Processing Register event for commit: $commit")

    name, ver, brn = register(get_clone_url(event), commit; registry=REGISTRY, push=true)
    make_pull_request(event, name, ver, brn)

    @info("Done processing event for commit: $commit")
end

function tester()
    global event_queue

    while true
        while !isempty(event_queue)
            event, t = dequeue!(event_queue)
            if t == :ci
                handle_ci_events(event)
            elseif t == :register
                handle_register_events(event)
            end
        end

        sleep(CYCLE_INTERVAL)
    end
end

function main()
    @async @recover tester()
    @recover start_github_webhook()
end

end    # module
