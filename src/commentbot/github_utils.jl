function register_rights_error(evt, user)
    if is_owned_by_organization(evt)
        org = evt.repository.owner.login
        return "**Register Failed**\n@$(user), it looks like you are not a publicly listed member/owner in the parent organization ($(org)).\nIf you are a member/owner, you will need to change your membership to public. See [GitHub Help](https://help.github.com/en/articles/publicizing-or-hiding-organization-membership)"
    else
        return "**Register Failed**\n@$(user), it looks like you don't have collaborator status on this repository."
    end
end

get_access_token(event) = create_access_token(Installation(event.payload["installation"]), get_jwt_auth())
get_user_auth() = GitHub.authenticate(CONFIG["github"]["token"])
get_jwt_auth() = GitHub.JWTAuth(CONFIG["github"]["app_id"], CONFIG["github"]["priv_pem"])

function get_sha_from_branch(reponame, brn; auth = GitHub.AnonymousAuth())
    try
        b = branch(reponame, Branch(brn); auth=auth)
        sha = b.sha !== nothing ? b.sha : b.commit.sha
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

is_owned_by_organization(event) = event.repository.owner.typ == "Organization"

function is_comment_by_collaborator(event)
    @debug("Checking if comment is by collaborator")
    user = get_user_login(event.payload)
    return iscollaborator(event.repository, user; auth=get_access_token(event))
end

function is_comment_by_org_owner_or_member(event)
    @debug("Checking if comment is by repository parent organization owner or member")
    org = event.repository.owner.login
    user = get_user_login(event.payload)
    if get(CONFIG, "check_private_membership", false)
        return GitHub.check_membership(org, user; auth=get_user_auth())
    else
        return GitHub.check_membership(org, user; public_only=true)
    end
end

has_register_rights(event) = is_comment_by_collaborator(event) || is_owned_by_organization(event) && is_comment_by_org_owner_or_member(event)

is_pull_request(payload::Dict{<:AbstractString}) = haskey(payload, "pull_request") || haskey(payload, "issue") && haskey(payload["issue"], "pull_request")
is_commit_comment(payload::Dict{<:AbstractString}) = haskey(payload, "comment") && !haskey(payload, "issue")

function get_prid(payload::Dict{<:AbstractString})
    if haskey(payload, "pull_request")
        return payload["pull_request"]["number"]
    elseif haskey(payload, "issue")
        return payload["issue"]["number"]
    else
        error("Don't know how to get pull request number")
    end
end

get_comment_commit_id(event) = event.payload["comment"]["commit_id"]
get_clone_url(event) = event.payload["repository"]["clone_url"]

function make_comment(evt::WebhookEvent, body::AbstractString)
    CONFIG["reply_comment"] || return
    @debug("Posting comment to PR/issue")
    headers = Dict("private_token" => CONFIG["github"]["token"])
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

function get_html_url(payload::Dict{<:AbstractString})
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

"""
    raise_issue(event::WebhookEvent, phrase::Regex, bt::String)
Open an issue in the configured Registrator repository. The issue
body will contain the trigger comment `phrase` and the backtrace
in `bt`. A link to the opened issue will be posted on the source
issue, PR or commit from which the `event` comes from.

This will also post the backtrace on the slack channel if
configured.
"""
function raise_issue(event::WebhookEvent, phrase::Regex, bt::String)
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

    slack_config = get(CONFIG, "slack", nothing)
    if (slack_config !== nothing) && get(slack_config, "alert", false)
        post_on_slack_channel(body, slack_config["token"], slack_config["channel"])
    end

    if CONFIG["report_issue"]
        params = Dict("title"=>title, "body"=>body)
        regrepo = CONFIG["issue_repo"]
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

function set_status(rp, state, desc)
     CONFIG["set_status"] || return
     repo = rp.reponame
     kind = rp.evt.kind
     payload = rp.evt.payload
     if kind == "pull_request"
         commit = payload["pull_request"]["head"]["sha"]
         params = Dict("state" => state,
                       "context" => CONFIG["github"]["user"],
                       "description" => desc)
         GitHub.create_status(repo, commit;
                              auth=get_access_token(rp.evt),
                              params=params)
     end
end

set_pending_status(rp) = set_status(rp, "pending", "Processing request...")
set_error_status(rp) = set_status(rp, "error", "Failed to register")
set_success_status(rp) = set_status(rp, "success", "Done")

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
       match(r"A pull request already exists", d["Errors"]) !== nothing
        return true
    end

    return false
end

function get_user_login(payload::Dict{<:AbstractString})
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

function get_body(payload::Dict{<:AbstractString})
    if haskey(payload, "comment")
        return payload["comment"]["body"]
    elseif haskey(payload, "issue")
        return payload["issue"]["body"]
    elseif haskey(payload, "pull_request")
        return payload["pull_request"]["body"]
    else
        error("Don't know how to get body")
    end
end

function create_or_find_pull_request(repo::AbstractString,
                                     params::Dict{<:AbstractString, Any},
                                     rbrn::RegBranch)
    pr = nothing
    msg = ""
    auth = get_user_auth()
    try
        pr = create_pull_request(repo; auth=auth, params=params)
        msg = "created"
        @debug("Pull request created")
        try # add labels
            if get(rbrn.metadata, "labels", nothing) !== nothing
                edit_issue(repo, pr; auth = get_user_auth(),
                    params = Dict("labels"=>rbrn.metadata["labels"]))
            end
        catch
            @debug "Failed to add labels, ignoring."
        end
    catch ex
        if is_pr_exists_exception(ex)
            @debug("Pull request already exists, not creating")
            msg = "updated"
        else
            rethrow(ex)
        end
    end

    if pr === nothing
        prs, _ = pull_requests(repo; auth=auth, params=Dict(
            "state" => "open",
            "base" => params["base"],
            "head" => string(split(repo, "/")[1], ":", params["head"]),
        ))
        if !isempty(prs)
            @assert length(prs) == 1 "PR lookup should only contain one result"
            @debug("PR found")
            pr = prs[1]
        end

        if pr === nothing
            error("Registration PR already exists but unable to find it")
        else
            update_pull_request(repo, pr.number; auth=auth, params=Dict("body" => params["body"]))
        end
    end

    return pr, msg
end
