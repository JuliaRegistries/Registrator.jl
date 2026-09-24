function tag_package(rname, ver::VersionNumber, mcs, auth; tag_name = "v$ver")
    tagger = Dict("name" => CONFIG["github"]["user"],
                  "email" => CONFIG["github"]["email"],
                  "date" => Dates.format(now(), dateformat"YYYY-mm-ddTHH:MM:SSZ"))
    create_tag(rname; auth=auth,
               params=Dict("tag" => tag_name,
                           "message" => "Release: $tag_name",
                           "object" => mcs,
                           "type" => "commit",
                           "tagger" => tagger))
end

# Keys `handle_approval` reads from the decrypted metadata.
const METADATA_KEYS = ("request_type", "pkg_repo_name", "trigger_id", "tree_sha", "version", "subdir")

# Registration metadata is embedded in the registry PR body as an HTML comment
# holding the hex-encoded ciphertext, `<!-- 0123abcd... -->`. The body can hold
# other HTML comments as well (the `<!-- BEGIN RELEASE NOTES -->` markers come
# *before* it, and users may edit the body), so only hex-only comments are
# candidates, and each one is tried until one decrypts and parses.
#
# Candidates are tried last-to-first: `pull_request_contents` appends the
# metadata after everything else, while the release notes above it are
# user-supplied. The ciphertext is deterministic and the same key is used for
# every PR, so a hex comment copied from another public registry PR into the
# release notes decrypts fine; scanning from the end keeps it from shadowing the
# bot's own metadata. Returns `nothing` when the body is missing or holds no
# valid metadata.
function metadata_from_pr_body(body::Union{AbstractString,Nothing}, key)
    body === nothing && return nothing
    for m in reverse(collect(eachmatch(r"<!--\s*([0-9a-fA-F]+)\s*-->", body)))
        meta = try
            JSON.parse(String(decrypt_metadata(key, hex2bytes(m.captures[1]))))
        catch ex
            @debug "Exception occured while parsing PR body" exception = (ex, catch_backtrace())
            continue
        end
        # There is no authentication, so a wrong key or unrelated hex can
        # decrypt to bytes that happen to parse as JSON (e.g. a bare number).
        # Only accept the shape `handle_approval` indexes into.
        meta isa AbstractDict && all(k -> haskey(meta, k), METADATA_KEYS) && return meta
        @debug "Decrypted PR metadata has unexpected shape" meta
    end
    nothing
end

function get_metadata_from_pr_body(rp::RequestParams, auth)
    pr = pull_request(rp.reponame, rp.trigger_src.prid; auth=auth)
    metadata_from_pr_body(pr.body, CONFIG["enc_key"])
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
    subdir = d["subdir"]

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
    tag = tag_name(ver, subdir)
    # Get tags in a try-catch block as GitHub.jl error if no tag exists
    try
        ts = tags(reponame; auth=auth, page_limit=1, params=Dict("per_page" => 15))[1]
        for t in ts
            if split(t.url.path, "/")[end] == tag
                if t.object["sha"] != tree_sha
                    return "Tag with name `$tag` already exists and points to a different commit"
                end
                tag_exists = true
                @debug("Tag already exists", reponame, ver, tree_sha)
                break
            end
        end
    catch e
        if occursin("Status Code: 404", e.msg)
            @debug("No tag exists", reponame)
        else
            rethrow(e)
        end
    end

    if !tag_exists
        @debug("Creating new tag", reponame, ver, tree_sha)
        tag_package(reponame, ver, tree_sha, auth; tag_name = tag)
    end

    release_exists = false
    if tag_exists
        # Look for release in last 15 releases
        rs = releases(reponame; auth=auth, page_limit=1, params=Dict("per_page"=>15))[1]
        for r in rs
            if r.name == tag
                release_exists = true
                @debug("Release already exists", r.name)
                break
            end
        end
    end

    if !release_exists
        @debug("Creating new release", ver)
        create_release(reponame; auth=auth,
                       params=Dict("tag_name" => tag, "name" => tag))
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
        @info "Unexpected error" exception = (ex, catch_backtrace())
    end
    @info("Done processing approval event", reponame=rp.reponame, rp.trigger_src.prid)
end

string(::RequestParams{ApprovalTrigger}) = "approval"
