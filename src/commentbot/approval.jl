function tag_package(rname, ver::VersionNumber, mcs, auth)
    tagger = Dict("name" => CONFIG["github"]["user"],
                  "email" => CONFIG["github"]["email"],
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

    key = CONFIG["enc_key"]
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

    if d === nothing
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

function print_entry_log(rp::RequestParams{ApprovalTrigger})
    @info "Approving Pull request" reponame=rp.reponame prid=rp.trigger_src.prid
end

function action(rp::RequestParams{ApprovalTrigger}, zsock)
    @info("Processing approval event", reponame=rp.reponame, rp.trigger_src.prid)
    try
        err = handle_approval(rp)
        if err !== nothing
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

string(::RequestParams{ApprovalTrigger}) = "approval"
