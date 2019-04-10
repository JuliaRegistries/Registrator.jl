module RegServer

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
import ..Registrator: post_on_slack_channel
import ..RegEdit: register, RegBranch
import Base: string

struct CommonParams
    isvalid::Bool
    error::Union{Nothing, String}
    report_error::Bool
end

abstract type RequestTrigger end
abstract type RegisterTrigger <: RequestTrigger end

struct PullRequestTrigger <: RegisterTrigger
    prid::Int
end

struct IssueTrigger <: RegisterTrigger
    branch::String
end

struct CommitCommentTrigger <: RegisterTrigger
end

struct ApprovalTrigger <: RequestTrigger
    prid::Int
end

struct EmptyTrigger <: RequestTrigger
end

struct RequestParams{T<:RequestTrigger}
    evt::WebhookEvent
    phrase::RegexMatch
    reponame::String
    trigger_src::T
    comment_by_collaborator::Bool
    target::Union{Nothing,String}
    cparams::CommonParams

    function RequestParams(evt::WebhookEvent, phrase::RegexMatch)
        reponame = evt.repository.full_name
        trigger_src = EmptyTrigger()
        comment_by_collaborator = false
        err = nothing
        report_error = false

        action_name, action_args, action_kwargs = parse_submission_string(strip(phrase.captures[1], '`'))
        target = get(action_kwargs, :target, nothing)

        if action_name == "register"
            if endswith(reponame, ".jl")
                comment_by_collaborator = is_comment_by_collaborator(evt)
                if comment_by_collaborator
                    @debug("Comment is by collaborator")
                    if is_pull_request(evt.payload)
                        if config["registrator"]["disable_pull_request_trigger"]
                            make_comment(evt, "Pull request comments will not trigger Registrator as it is disabled. Please trying using a commit or issue comment.")
                        else
                            @debug("Comment is on a pull request")
                            prid = get_prid(evt.payload)
                            trigger_src = PullRequestTrigger(prid)
                        end
                    elseif is_commit_comment(evt.payload)
                        @debug("Comment is on a commit")
                        trigger_src = CommitCommentTrigger()
                    else
                        @debug("Comment is on an issue")
                        brn = get(action_kwargs, :branch, "master")
                        @debug("Will use branch", brn)
                        trigger_src = IssueTrigger(brn)
                    end
                else
                    err = "Comment not made by collaborator"
                    @debug(err)
                end
                @debug("Comment is on a pull request")
            else
                err = "Package name does not end with '.jl'"
                @debug(err)
                report_error = true
            end
        elseif action_name == "approved"
            if config["registrator"]["disable_approval_process"]
                make_comment(evt, "The `approved()` command is disabled.")
            else
                registry_repos = [join(split(r["repo"], "/")[end-1:end], "/") for (n, r) in config["targets"]]
                if reponame in registry_repos
                    @debug("Recieved approval comment")
                    comment_by_collaborator = is_comment_by_collaborator(evt)
                    if comment_by_collaborator
                        @debug("Comment is by collaborator")
                        if is_pull_request(evt.payload)
                            prid = get_prid(evt.payload)
                            trigger_src = ApprovalTrigger(prid)
                        end
                    else
                        err = "Comment not made by collaborator"
                        @debug(err)
                    end
                else
                    @debug("Approval comment not made on a valid registry")
                end
            end
        else
            err = "Action not recognized: $action_name"
            @debug(err)
            report_error = true
        end

        isvalid = comment_by_collaborator
        @debug("Event pre-check validity: $isvalid")

        return new{typeof(trigger_src)}(evt, phrase, reponame, trigger_src,
                                        comment_by_collaborator, target,
                                        CommonParams(isvalid, err, report_error))
    end
end

function tag_package(rname, ver::VersionNumber, mcs, auth)
    tagger = Dict("name" => config["github"]["user"],
                  "email" => config["github"]["email"],
                  "date" => Dates.format(now(), dateformat"YYYY-mm-ddTHH:MM:SSZ"))
    create_tag(rname; auth=auth,
               params=Dict("tag" => "v$ver",
                           "message" => "Release: v$ver",
                           "object" => mcs,
                           "type" => "commit",
                           "tagger" => tagger))
end

function get_metadata_from_pr_body(rp::RequestParams, auth)
    reg_name = rp.reponame
    reg_prid = rp.trigger_src.prid

    pr = pull_request(reg_name, reg_prid; auth=auth)

    mstart = match(r"<!--", pr.body)
    mend = match(r"-->", pr.body)

    key = config["registrator"]["enc_key"]
    try
        enc_meta = strip(pr.body[mstart.offset+4:mend.offset-1])
        meta = String(decrypt(MbedTLS.CIPHER_AES_128_CBC, key, hex2bytes(enc_meta), key))
        return JSON.parse(meta)
    catch ex
        @debug("Exception occured while parsing PR body", get_backtrace(ex))
    end

    nothing
end

function handle_approval(rp::RequestParams{ApprovalTrigger})
    auth = get_access_token(rp.evt)
    d = get_metadata_from_pr_body(rp, auth)

    if d == nothing
        return "Unable to get registration metdata for this PR"
    end

    reg_name = rp.reponame
    reg_prid = rp.trigger_src.prid
    reponame = d["pkg_repo_name"]
    ver = VersionNumber(d["version"])
    tree_sha = d["tree_sha"]
    trigger_id = d["trigger_id"]
    request_type = d["request_type"]

    if request_type == "pull_request"
        pr = pull_request(reponame, trigger_id; auth=auth)
        tree_sha = pr.merge_commit_sha
        if pr.state == "open"
            @debug("Merging pull request on package repo", reponame, trigger_id)
            merge_pull_request(reponame, trigger_id; auth=auth,
                               params=Dict("merge_method" => "squash"))
        else
            @debug("Pull request already merged", reponame, trigger_id)
        end
    end

    tag_exists = false
    ts = tags(reponame; auth=auth, page_limit=1, params=Dict("per_page" => 15))[1]
    for t in ts
        if split(t.url.path, "/")[end] == "v$ver"
            if t.object["sha"] != tree_sha
                return "Tag with name `v$ver` already exists and points to a different commit"
            end
            tag_exists = true
            @debug("Tag already exists", reponame, ver, tree_sha)
            break
        end
    end

    if !tag_exists
        @debug("Creating new tag", reponame, ver, tree_sha)
        tag_package(reponame, ver, tree_sha, auth)
    end

    release_exists = false
    if tag_exists
        # Look for release in last 15 releases
        rs = releases(reponame; auth=auth, page_limit=1, params=Dict("per_page"=>15))[1]
        for r in rs
            if r.name == "v$ver"
                release_exists = true
                @debug("Release already exists", r.name)
                break
            end
        end
    end

    if !release_exists
        @debug("Creating new release", ver)
        create_release(reponame; auth=auth,
                       params=Dict("tag_name" => "v$ver", "name" => "v$ver"))
    end

    if request_type == "issue"
        iss = issue(reponame, Issue(trigger_id); auth=auth)
        if iss.state == "open"
            @debug("Closing issue", reponame, trigger_id)
            edit_issue(reponame, trigger_id; auth=auth, params=Dict("state"=>"closed"))
        else
            @debug("Issue already closed", reponame, trigger_id)
        end
    end

    reg_pr = pull_request(reg_name, reg_prid; auth=auth)
    if reg_pr.state == "open"
        @debug("Merging pull request on registry", reg_name, reg_prid)
        merge_pull_request(reg_name, reg_prid; auth=auth)
    else
        @debug("Pull request on registry already merged", reg_name, reg_prid)
    end
    nothing
end

function get_cloneurl_and_sha(rp::RequestParams{PullRequestTrigger}, auth)
    pr = pull_request(rp.reponame, rp.trigger_src.prid; auth=auth)
    cloneurl = pr.head.repo.html_url.uri * ".git"
    sha = pr.head.sha

    cloneurl, sha, nothing
end

function get_cloneurl_and_sha(rp::RequestParams{CommitCommentTrigger}, auth)
    cloneurl = get_clone_url(rp.evt)
    sha = get_comment_commit_id(rp.evt)

    cloneurl, sha, nothing
end

function get_cloneurl_and_sha(rp::RequestParams{IssueTrigger}, auth)
    cloneurl = get_clone_url(rp.evt)
    sha, err = get_sha_from_branch(rp.reponame, rp.trigger_src.branch; auth=auth)

    cloneurl, sha, err
end

struct ProcessedParams
    projectfile_contents::Union{Nothing, String}
    projectfile_found::Bool
    projectfile_valid::Bool
    sha::Union{Nothing, String}
    tree_sha::Union{Nothing, String}
    cloneurl::Union{Nothing, String}
    cparams::CommonParams

    function ProcessedParams(rp::RequestParams)
        if rp.cparams.error != nothing
            @debug("Pre-check failed, not processing RequestParams: $(rp.cparams.error)")
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

        cloneurl, sha, err = get_cloneurl_and_sha(rp, auth)

        if err == nothing && sha != nothing
            projectfile_contents, tree_sha, projectfile_found, projectfile_valid, err = verify_projectfile_from_sha(rp.reponame, sha; auth = auth)
            if !projectfile_found
                err = "Project file not found on branch `$(rp.trigger_src.branch)`"
                @debug(err)
            end
        end

        isvalid = rp.comment_by_collaborator && projectfile_found && projectfile_valid
        @debug("Event validity: $(isvalid)")

        new(projectfile_contents, projectfile_found, projectfile_valid, sha, tree_sha, cloneurl,
            CommonParams(isvalid, err, report_error))
    end
end

# `x` can only be Expr, Symbol, QuoteNode, T<:Number, or T<:AbstractString
phrase_argument(x::Union{Expr, Symbol, QuoteNode}) = string(x)
phrase_argument(x::Union{AbstractString, Number})  = repr(x)

function parse_submission_string(fncall)
    argind = findfirst(isequal('('), fncall)
    name = fncall[1:(argind - 1)]
    parsed_args = Meta.parse(replace(fncall[argind:end], ";" => ","))
    args, kwargs = Vector{String}(), Dict{Symbol,String}()
    if isa(parsed_args, Expr) && parsed_args.head == :tuple
        started_kwargs = false
        for x in parsed_args.args
            if isa(x, Expr) && (x.head == :kw || x.head == :(=)) && isa(x.args[1], Symbol)
                @assert !haskey(kwargs, x.args[1]) "kwargs must all be unique"
                kwargs[x.args[1]] = phrase_argument(x.args[2])
                started_kwargs = true
            else
                @assert !started_kwargs "kwargs must come after other args"
                push!(args, phrase_argument(x))
            end
        end
    elseif isa(parsed_args, Expr) && parsed_args.head == :(=) && isa(parsed_args.args[1], Symbol)
        kwargs[parsed_args.args[1]] = phrase_argument(parsed_args.args[2])
    else
        push!(args, phrase_argument(parsed_args))
    end
    return name, args, kwargs
end

const event_queue = Channel{RequestParams}(1024)
const config = Dict{String,Any}()
const httpsock = Ref{Sockets.TCPServer}()

function get_access_token(event)
    create_access_token(Installation(event.payload["installation"]), get_jwt_auth())
end

function get_user_auth()
    GitHub.authenticate(config["github"]["token"])
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
        elseif !isempty(p.version.prerelease)
            err = "Pre-release version not allowed"
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
                a = get_user_auth()
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
    auth = get_user_auth()
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
        iss = create_issue(regrepo; params=params, auth=get_user_auth())
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

function print_entry_log(rp::RequestParams{PullRequestTrigger})
    @info("Creating registration pull request for $(rp.reponame) PR: $(rp.trigger_src.prid)")
end

function print_entry_log(rp::RequestParams{CommitCommentTrigger})
    @info("Creating registration pull request for $(rp.reponame) sha: `$(get_comment_commit_id(rp.evt))`")
end

function print_entry_log(rp::RequestParams{IssueTrigger})
    @info("Creating registration pull request for $(rp.reponame) branch: `$(rp.trigger_src.branch)`")
end

function print_entry_log(rp::RequestParams{ApprovalTrigger})
    @info("Approving Pull request  $(rp.reponame)/$(rp.trigger_src.prid)")
end

function handle_comment_event(event::WebhookEvent, phrase::RegexMatch)
    rp = RequestParams(event, phrase)
    isa(rp.trigger_src, EmptyTrigger) && rp.cparams.error == nothing && return

    if rp.cparams.isvalid && rp.cparams.error == nothing
        print_entry_log(rp)

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
    key = config["registrator"]["enc_key"]
    enc_meta = "<!-- " * bytes2hex(encrypt(MbedTLS.CIPHER_AES_128_CBC, key, meta, key)) * " -->"
    params = Dict("title"=>"Register $name: $ver",
                  "base"=>target_registry["base_branch"],
                  "head"=>brn,
                  "maintainer_can_modify"=>true)
    ref = get_html_url(rp.evt.payload)
    params["body"] = """
| $name       |     $ver     |
|-------------|--------------|
| Proposed by | @$(creator)  |
| Reviewed by | @$(reviewer) |
| Reference   | [$ref]($ref) |

$enc_meta
"""

    pr = nothing
    repo = join(split(target_registry["repo"], "/")[end-1:end], "/")
    msg = ""
    try
        pr = create_pull_request(repo; auth=get_user_auth(), params=params)
        msg = "created"
        @debug("Pull request created")
    catch ex
        if is_pr_exists_exception(ex)
            @debug("Pull request already exists, not creating")
            msg = "updated"
        else
            rethrow(ex)
        end
    end

    if pr == nothing
        # Look for pull request in last 10 pages, each page contains 15 PRs
        params = Dict("state"=>"open", "per_page"=>15)
        auth = get_user_auth()
        prs, page_data = pull_requests(repo; auth=auth, params=params, page_limit=1)
        for p in prs
            if p.base.ref == target_registry["base_branch"] && p.head.ref == brn
                @debug("PR found")
                pr = p
                break
            end
        end

        if pr == nothing
            i = 1
            while i < 10
                prs, page_data = pull_requests(repo; auth=auth, page_limit=1, start_page=page_data["next"]);
                for p in prs
                    if p.base.ref == target_registry["base_branch"] && p.head.ref == brn
                        @debug("PR found")
                        pr = p
                        break
                    end
                end
                pr == nothing || break
                i += 1
            end
        end

        pr == nothing && error("Registration PR already exists but unable to find it")
    end

    cbody = """
        Registration pull request $msg: [$(repo)/$(pr.number)]($(pr.html_url))

        After the above pull request is merged, it is recommended that you create
        a tag on this repository for the registered package version:
        ```
        git tag -a v$(string(ver)) -m "<description of version>" $(pp.tree_sha)
        git push v$(string(ver))
        ```
        """

    if rbrn.warning !== nothing
        cbody += """
            Also, note the warning: $(rbrn.warning)
            This can be safely ignored. However, if you want to fix this you can do so. Call register() again after making the fix. This will update the Pull request.
            """
    end

    @debug(cbody)
    make_comment(rp.evt, cbody)
    return pr
end

function handle_events(rp::RequestParams{T}) where T <: RegisterTrigger
    targets = (rp.target === nothing) ? config["targets"] : filter(x->(x[1]==rp.target), config["targets"])
    for (target_registry_name,target_registry) in targets
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

function handle_events(rp::RequestParams{ApprovalTrigger})
    @info("Processing approval event", reponame=rp.reponame, rp.trigger_src.prid)
    try
        err = handle_approval(rp)
        if err != nothing
            @debug(err)
            make_comment(rp.evt, "Error in approval process: $err")
        end
    catch ex
        bt = get_backtrace(ex)
        @info("Unexpected error: $bt")
        raise_issue(rp.evt, rp.phrase, bt)
    end
    @info("Done processing approval event", reponame=rp.reponame, rp.trigger_src.prid)
end

string(::RequestParams{PullRequestTrigger}) = "pull_request"
string(::RequestParams{CommitCommentTrigger}) = "commit_comment"
string(::RequestParams{IssueTrigger}) = "issue"
string(::RequestParams{ApprovalTrigger}) = "approval"

function handle_register(rp::RequestParams, target_registry::Dict{String,Any})
    pp = ProcessedParams(rp)

    if pp.cparams.isvalid && pp.cparams.error == nothing
        rbrn = register(pp.cloneurl, Pkg.Types.read_project(copy(IOBuffer(pp.projectfile_contents))), pp.tree_sha;
            registry=target_registry["repo"],
            registry_deps=get(config["registrator"], "registry_deps", String[]),
            push=true,
            gitconfig=Dict("user.name"=>config["github"]["user"], "user.email"=>config["github"]["email"]))
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
    do_action() = handle_events(take!(event_queue))
    handle_exception(ex) = (isa(ex, InvalidStateException) && (ex.state == :closed)) ? :exit : :continue
    keep_running() = isopen(event_queue)
    recover("request_processor", keep_running, do_action, handle_exception)
end

function github_webhook(http_ip=config["server"]["http_ip"], http_port=get(config["server"], "http_port", parse(Int, get(ENV, "PORT", "8001"))))
    auth = get_jwt_auth()
    trigger = Regex("@$(config["registrator"]["trigger"]) (.*?)\$")
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
