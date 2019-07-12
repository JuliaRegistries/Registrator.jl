struct CommonParams
    isvalid::Bool
    error::Union{Nothing, String}
    report_error::Bool
end

struct RequestParams{T<:RequestTrigger}
    evt::WebhookEvent
    phrase::RegexMatch
    reponame::String
    release_notes::String
    trigger_src::T
    commenter_can_register::Bool
    target::Union{Nothing,String}
    cparams::CommonParams

    function RequestParams(evt::WebhookEvent, phrase::RegexMatch)
        reponame = evt.repository.full_name
        user = get_user_login(evt.payload)
        trigger_src = EmptyTrigger()
        notes = ""
        commenter_can_register = false
        err = nothing
        report_error = false

        text = strip(phrase[1], [' ', '`'])
        action_name, action_kwargs = parse_comment(text)
        if action_name === nothing
            return new{typeof(trigger_src)}(
                evt, phrase, reponame, notes, trigger_src,
                commenter_can_register, nothing,
                CommonParams(false, "Invalid trigger, ignoring", report_error),
            )
        end

        branch = get(action_kwargs, :branch, "master")
        target = get(action_kwargs, :target, nothing)

        if evt.payload["repository"]["private"] && get(CONFIG, "disable_private_registrations", true)
            err = "Private package registration request received, ignoring"
            @debug(err)
        elseif action_name == "register"
            commenter_can_register = has_register_rights(evt)
            if commenter_can_register
                @debug("Commenter has registration rights")
                notes_match = match(r"(?:patch|release) notes:(.*)"si, get_body(evt.payload))
                notes = notes_match === nothing ? "" : strip(notes_match[1])
                if is_pull_request(evt.payload)
                    if CONFIG["disable_pull_request_trigger"]
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
                    @debug("Will use branch", branch)
                    trigger_src = IssueTrigger(branch)
                end
            else
                err = register_rights_error(evt, user)
                @debug(err)
                report_error = true
            end
            @debug("Comment is on a pull request")
        elseif action_name == "approved"
            if CONFIG["disable_approval_process"]
                make_comment(evt, "The `approved()` command is disabled.")
            else
                registry_repos = [join(split(r["repo"], "/")[end-1:end], "/") for (n, r) in CONFIG["targets"]]
                if reponame in registry_repos
                    @debug("Recieved approval comment")
                    commenter_can_register = has_register_rights(evt)
                    if commenter_can_register
                        @debug("Commenter has register rights")
                        if is_pull_request(evt.payload)
                            prid = get_prid(evt.payload)
                            trigger_src = ApprovalTrigger(prid)
                        end
                    else
                        err = register_rights_error(evt, user)
                        @debug(err)
                        report_error = true
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

        isvalid = commenter_can_register
        @debug("Event pre-check validity: $isvalid")

        return new{typeof(trigger_src)}(evt, phrase, reponame, notes, trigger_src,
                                        commenter_can_register, target,
                                        CommonParams(isvalid, err, report_error))
    end
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

function istagwrong(
    rp::RequestParams,
    commit_sha::String,
    ver::VersionNumber,
    auth,
)
    # Look for tag in last 15 tags
    ts = try
        tags(rp.reponame; auth=auth, page_limit=1,
             params=Dict("per_page" => 15))[1]
    catch ex
        []
    end
    ver = string(ver)
    for t in ts
        tag_name = split(t.url.path, "/")[end]
        if startswith(tag_name, "v")
            tag_name = tag_name[2:end]
        end
        if tag_name == ver
            if t.object["sha"] != commit_sha
                return true
            end
            break
        end
    end
    false
end

struct ProcessedParams
    project::Union{Nothing, Pkg.Types.Project}
    projectfile_found::Bool
    projectfile_valid::Bool
    sha::Union{Nothing, String}
    tree_sha::Union{Nothing, String}
    cloneurl::Union{Nothing, String}
    cparams::CommonParams

    function ProcessedParams(rp::RequestParams)
        if rp.cparams.error !== nothing
            @debug("Pre-check failed, not processing RequestParams: $(rp.cparams.error)")
            return ProcessedParams(nothing, nothing, copy(rp.cparams))
        end

        project = nothing
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

        if err === nothing && sha !== nothing
            project, tree_sha, projectfile_found, projectfile_valid, err = verify_projectfile_from_sha(rp.reponame, sha; auth = auth)
            if !projectfile_found
                err = "File (Julia)Project.toml not found"
                @debug(err)
            end
        end

        wrongtag = false
        if err === nothing
            wrongtag = istagwrong(rp, sha, project.version, auth)
            if wrongtag
                err = "Tag with name `$(project.version)` already exists and points to a different commit"
                @debug(err, rp.reponame, project.version)
            end
        end

        isvalid = rp.commenter_can_register && projectfile_found && projectfile_valid && !wrongtag
        @debug("Event validity: $(isvalid)")

        new(project, projectfile_found, projectfile_valid, sha, tree_sha, cloneurl,
            CommonParams(isvalid, err, report_error))
    end
end
