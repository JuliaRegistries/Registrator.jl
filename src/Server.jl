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
    listener = GitHub.EventListener(event_handler; auth=auth, secret=GITHUB_SECRET, events=events)
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

function is_approved_by_collaborator(event)
    @info("Checking for approval by collaborator")
    r = event.payload["review"]
    if r["state"] == "approved"
        @info("PR is approved")
        user = r["user"]["login"]
        auth = get_jwt_auth()
        tok = create_access_token(Installation(event.payload["installation"]), auth)
        if iscollaborator(event.repository, user; auth=tok)
            @info("Approval done by collaborator")
            return true
        else
            @info("Approval not done by collaborator")
            return false
        end
    end

    @info("PR is not approved")
    return false
end

"""
The webhook handler.
"""
function event_handler(event::WebhookEvent)
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

get_prid(event) = event.payload["pull_request"]["number"]
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

function handle_register_events(event)
    commit = get_commit(event)

    @info("Processing Register event for commit: $commit")

    register(event.payload["repository"]["clone_url"], commit; registry=REGISTRY, push=true)

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
