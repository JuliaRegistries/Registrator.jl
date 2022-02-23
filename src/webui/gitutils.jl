using ..Registrator: decodeb64
using Mocking

config(::GitHub.Repo) = CONFIG["github"]
config(::GitLab.Project) = CONFIG["gitlab"]
config(::Bitbucket.Repo) = CONFIG["bitbucket"]
provider(::Union{GitHubAPI, GitHub.Repo}) = PROVIDERS["github"]
provider(::Union{GitLabAPI, GitLab.Project}) = PROVIDERS["gitlab"]
provider(::Union{BitbucketAPI, Bitbucket.Repo}) = PROVIDERS["bitbucket"]

# # Run some GitForge function, warning on error but still returning the value.
macro gf(ex::Expr)
    quote
        try
            $(esc(ex))[1]
        catch err
            println("API request failed\n  ", err, "\n  ", join(stacktrace(catch_backtrace()), "\n  "))
            @warn "API request failed" exception=err,catch_backtrace()
            nothing
        end
    end
end

# Split a repo path into its owner and name.
function splitrepo(url::AbstractString)
    pieces = split(HTTP.URI(url).path, "/"; keepempty=false)
    owner = join(pieces[1:end-1], "/")
    name = pieces[end]
    return owner, name
end

# Look up a repository.
getrepo(api, owner::AbstractString, name::AbstractString) =
    @gf get_repo(provider(api).client, owner, name)

abstract type AuthResult end
struct AuthSuccess <: AuthResult end
struct AuthFailure <: AuthResult
    reason::AbstractString
end

is_success(res::AuthSuccess) = true
is_success(res::AuthFailure) = false

# Check for a user's authorization to release a package.
# The criteria is simply whether the user is a collaborator for user-owned repos,
# or whether they're an organization member or collaborator for organization-owned repos.
isauthorized(u, repo) = AuthFailure("Unkown user type or repo type")
function isauthorized(u::User{GitHub.User}, repo::GitHub.Repo)
    if !get(CONFIG, "allow_private", false)
        repo.private && return AuthFailure("Repo $(repo.name) is private")
    end

    if repo.private
        forge = provider(repo).client
    else
        forge = u.forge
    end

    if repo.organization === nothing
        hasauth = @gf @mock is_collaborator(forge, repo.owner.login, repo.name, u.user.login)
        if something(hasauth, false)
            return AuthSuccess()
        else
            return AuthFailure("User $(u.user.login) is not a collaborator on repo $(repo.name)")
        end
    else
        # First check for organization membership, and fall back to collaborator status.
        ismember = @gf @mock is_member(forge, repo.organization.login, u.user.login)
        hasauth = something(ismember, false) ||
            @gf @mock is_collaborator(forge, repo.organization.login, repo.name, u.user.login)
        if something(hasauth, false)
            return AuthSuccess()
        else
            return AuthFailure("User $(u.user.login) is not a member of the org $(repo.organization.login) and not a collaborator on repo $(repo.name)")
        end
    end
end

function isauthorized(u::User{GitLab.User}, repo::GitLab.Project)
    if !get(CONFIG, "allow_private", false)
        repo.visibility == "private" && return AuthFailure("Project $(repo.name) is private")
    end

    if repo.visibility == "private"
        forge = provider(repo).client
    else
        forge = u.forge
    end

    if repo.namespace.kind == "user"
        hasauth = @gf @mock is_collaborator(forge, repo.namespace.full_path, repo.name, u.user.id)
        if something(hasauth, false)
            return AuthSuccess()
        else
            return AuthFailure("User $(u.user.name) is not a member of project $(repo.name)") # GitLab terminology "member" (not "collaborator")
        end
    else
        # Same as above: group membership then collaborator check.
        nspath = split(repo.namespace.full_path, "/")
        ismember = @gf @mock is_collaborator(u.forge, repo.namespace.full_path, repo.name, u.user.id)
        if !something(ismember, false)
            accns = ""
            for ns in nspath
                accns = joinpath(accns, ns)
                ismember = @gf @mock is_member(forge, accns, u.user.id)
                something(ismember, false) && break
            end
        end
        if something(ismember, false)
            return AuthSuccess()
        else
            return AuthFailure("Project $(repo.name) belongs to the group $(repo.namespace.full_path), and user $(u.user.name) is not a member of that group or its parent group(s)")
        end
    end
end

function isauthorized(u::User{Bitbucket.User}, repo::Bitbucket.Repo)
    if !get(CONFIG, "allow_private", false)
        repo.is_private && return AuthFailure("Repo $(repo.slug) is private")
    end

    if repo.is_private
        bbforge = provider(repo).client
    else
        bbforge = u.forge
    end

    # First check for organization membership, and fall back to collaborator status.
    ismember = @gf @mock is_member(bbforge, repo.workspace.slug, u.user.uuid)
    hasauth = something(ismember, false) ||
        @gf @mock is_collaborator(bbforge, repo.workspace.slug, repo.slug, u.user.uuid)
    if something(hasauth, false)
        return AuthSuccess()
    else
        return AuthFailure("User $(u.user.nickname) is not a member of the workspace $(repo.workspace.slug) or a collaborator on repo $(repo.slug)")
    end
end

# Get the raw (Julia)Project.toml text from a repository.
function gettoml(::GitHubAPI, repo::GitHub.Repo, ref::AbstractString, subdir::AbstractString)
    forge = provider(repo).client
    lasterr = nothing
    for file in Base.project_names
        try
            fc, _ = get_file_contents(forge, repo.owner.login, repo.name, joinpath(subdir, file); ref=ref)
            return decodeb64(fc.content)
        catch err
            lasterr = err
        end
    end
    @error "Failed to get project file" exception=lasterr
    return nothing
end

function gettoml(::GitLabAPI, repo::GitLab.Project, ref::AbstractString, subdir::AbstractString)
    forge = provider(repo).client
    lasterr = nothing
    for file in Base.project_names
        try
            fc, _ = get_file_contents(forge, repo.id, joinpath(subdir, file); ref=ref)
            return decodeb64(fc.content)
        catch err
            lasterr = err
        end
    end
    @error "Failed to get project file" exception=lasterr
    return nothing
end

function gettoml(::BitbucketAPI, repo::Bitbucket.Repo, ref::AbstractString, subdir::AbstractString)
    bbforge = provider(repo).client
    lasterr = nothing
    for file in Base.project_names
        try
            fc, _ = get_file_contents(bbforge, repo.workspace.slug, repo.slug, joinpath(subdir, file); ref=ref)
            return fc
        catch err
            lasterr = err
        end
    end
    @error "Failed to get project file" exception=lasterr
    return nothing
end

function getcommithash(::GitHubAPI, repo::GitHub.Repo, ref::AbstractString)
    forge = provider(repo).client
    commit = @gf get_commit(forge, repo.owner.login, repo.name, ref)
    return commit === nothing ? nothing : commit.sha
end

function getcommithash(::GitLabAPI, repo::GitLab.Project, ref::AbstractString)
    forge = provider(repo).client
    commit = @gf get_commit(forge, repo.id, ref)
    return commit === nothing ? nothing : commit.id
end

function getcommithash(::BitbucketAPI, repo::Bitbucket.Repo, ref::AbstractString)
    bbforge = provider(repo).client
    commit = @gf get_commit(bbforge, repo.workspace.slug, repo.slug, ref)
    return commit === nothing ? nothing : commit.hash
end

# Get a repo's clone URL.
function cloneurl(r::GitHub.Repo, is_ssh::Bool=false)
    url = is_ssh ? r.ssh_url : r.clone_url
    println("URL: $(url)")
    # For private repositories, we need to insert the token into the URL.
    host = URI(url).host
    token = config(r)["token"]
    replace(url, host => "oauth2:$token@$host")
end
function cloneurl(r::GitLab.Project, is_ssh::Bool=false)
    url = is_ssh ? r.ssh_url_to_repo : r.http_url_to_repo
    println("URL: $(url)")
    # For private repositories, we need to insert the token into the URL.
    host = URI(url).host
    token = config(r)["token"]
    replace(url, host => "oauth2:$token@$host")
end
function cloneurl(r::Bitbucket.Repo, is_ssh::Bool=false)
    link = filter(l-> l.name == (is_ssh ? "ssh" : "https"), r.links.clone)
    isempty(link) && throw(ArgumentError("No $(is_ssh ? "ssh" : "https") repository URL"))
    token = config(r)["token"]
    string(URI(URI(link[1].href); userinfo=token))
end

function gettreesha(
    r::Union{GitLab.Project, GitHub.Repo, Bitbucket.Repo},
    ref::AbstractString,
    subdir::AbstractString
)
    return try
        url = cloneurl(r)
        mktempdir() do dir
            dest = joinpath(dir, r.name)
            run(`git clone --bare $url $dest`)
            readchomp(`git -C $dest rev-parse $ref:$subdir`), ""
        end
    catch ex
        println(get_backtrace(ex))
        nothing, "Exception while getting tree SHA"
    end
end

function ensure_already_exists(f::Function, resp::HTTP.Response, status::Int)
    resp.status == status || return false
    data = JSON.parse(String(copy(resp.body)))
    any(e -> occursin("already exists", e), f(data))
end

"""
    make_registration_request(
        registry::Registry{F},
        branch::AbstractString,
        title::AbstractString,
        body::AbstractString,
    ) where F <: GitForge.Forge
Try to create a pull request. If pull request already exists update the title and body.

Parameters:
- `registry`: The registry to create/update the pull request on
- `branch`: The head of the pull request
- `title`
- `body`

Returns:
A GitForge.Result object
"""
function make_registration_request(
    r::Registry{GitLabAPI},
    branch::AbstractString,
    title::AbstractString,
    body::AbstractString,
)
    repoid = r.repo.id
    base = r.repo.default_branch
    try
        result, _ = create_pull_request(
            r.forge, repoid;
            source_branch=branch,
            target_branch=base,
            title=title,
            description=body,
            remove_source_branch=true,
        )
        result, nothing
    catch ex
        resp = ex isa GitForge.HTTPError || ex isa GitForge.PostProcessorError ? ex.response : nothing
        if !ensure_already_exists(data -> get(data, "message", String[]), resp, 409)
            @error "Exception making registration request" repoid=repoid base=base head=branch
            return result, nothing
        end

        val, _ = get_pull_requests(r.forge, repoid; source_branch=branch, target_branch=base, state="opened")
        @assert length(val) == 1
        prid = first(val).iid
        update_pull_request(r.forge, repoid, prid; title=title, body=body)
        val, nothing
    end
end

function make_registration_request(
    r::Registry{GitHubAPI},
    branch::AbstractString,
    title::AbstractString,
    body::AbstractString,
)
    owner = r.repo.owner.login
    repo = r.repo.name
    base = r.repo.default_branch
    try
        result, _ = create_pull_request(
            r.forge, owner, repo;
            head=branch,
            base=base,
            title=title,
            body=body,
        )
        result, nothing
    catch ex
        resp = ex isa GitForge.HTTPError || ex isa GitForge.PostProcessorError ? ex.response : nothing
        exists = ensure_already_exists(resp, 422) do data
            map(e -> get(e, "message", ""), get(data, "errors", []))
        end
        if !exists
            @error "Exception making registration request" owner=owner repo=repo base=base head=branch
            return result, nothing
        end

        val, _ = get_pull_requests(r.forge, owner, repo; head="$owner:$branch", base=base, state="open")
        @assert length(val) == 1
        prid = first(val).number
        update_pull_request(r.forge, owner, repo, prid; title=title, body=body)
        val, nothing
    end
end

function make_registration_request(
    r::Registry{BitbucketAPI},
    branch::AbstractString,
    title::AbstractString,
    body::AbstractString,
)
    owner = r.repo.workspace.slug
    repo = r.repo.slug
    base = r.repo.mainbranch
    try
        result, _ = create_pull_request(
            r.forge, owner, repo;
            title=title,
            source=(; branch=(; name=branch)),
            description=body,
        )
        result, nothing
    catch ex
        resp = ex isa GitForge.HTTPError || ex isa GitForge.PostProcessorError ? ex.response : nothing
        resp === nothing && println("create_pull_request failed\n  ", ex, "\n  ", join(stacktrace(catch_backtrace()), "\n  "))
        exists = ensure_already_exists(resp, 422) do data
            map(e -> get(e, "message", ""), get(data, "errors", []))
        end
        if !exists
            @error "Exception making registration request" owner=owner repo=repo base=base head=branch exception=ex, catch_backtrace()
            rethrow(ex)
        end

        val, _ = get_pull_requests(r.forge, owner, repo; query=Dict(
        :q=> replace("""
            source.branch.name = \"$branch\" AND
            author.username \"$owner\" AND
            destination.branch.name = \"$base\"""", "\n"=> " ")
        ))
        @assert length(val) == 1
        prid = first(val).id
        update_pull_request(r.forge, owner, repo, prid; title=title, body=body)
        val, nothing
    end
end

# Get the web URL of various Git things.
web_url(pr::GitHub.PullRequest) = pr.html_url
web_url(mr::GitLab.MergeRequest) = mr.web_url
web_url(pr::Bitbucket.PullRequest) = pr.links.html.href
web_url(u::GitHub.User) = u.html_url
web_url(u::GitLab.User) = u.web_url
web_url(u::Bitbucket.User) = u.links.html.href
web_url(r::GitHub.Repo) = r.html_url
web_url(r::GitLab.Project) = r.web_url
web_url(r::Bitbucket.Repo) = r.links.html.href


# Get a user's @ mention.
mention(u::GitHub.User) = "@$(u.login)"
mention(u::GitLab.User) = "@$(u.username)"
mention(u::Bitbucket.User) = "@$(u.username)"

# Get a user's representation for a registry PR.
# If the registry is from the same provider, mention the user, otherwise use the URL.
display_user(u::U) where U =
    (parentmodule(typeof(REGISTRY[].repo)) === parentmodule(U) ? mention : web_url)(u)

function istagwrong(
    ::GitHubAPI,
    repo::GitHub.Repo,
    tag::VersionNumber,
    commit::String,
)
    result = @gf get_tags(provider(repo).client, repo.owner.login, repo.name)

    if result === nothing
        @debug("Could not fetch tags")
        return false
    end

    for t in result
        v = split(t.ref, "/")[end]
        if startswith(v, "v")
            v = v[2:end]
        end
        if v == string(tag)
            if t.object !== nothing && t.object.sha != commit
                return true
            end
            break
        end
    end
    false
end

function istagwrong(
    ::GitLabAPI,
    project::GitLab.Project,
    tag::VersionNumber,
    commit::String,
)
    # Using Registrator's token here instead of the users. This is
    # because the user oauth scope needs to include "api" in order to
    # get the tags which we can't ask for since "api" is `write` privilege.
    # Below line will not work for private packages. For private packages
    # we need to ask for "api" scope.
    result = @gf get_tags(provider(project).client, project.id)

    if result === nothing
        @debug("Could not fetch tags")
        return false
    end

    for t in result
        v = t.name
        if startswith(v, "v")
            v = v[2:end]
        end
        if v == string(tag)
            if t.commit !== nothing && t.commit.id != commit
                return true
            end
            break
        end
    end
    false
end

function istagwrong(
    api::BitbucketAPI,
    repo::Bitbucket.Repo,
    tag::VersionNumber,
    commit::String,
)
    try
        # Using Registrator's token here instead of the users. This is
        # because the user oauth scope needs to include "api" in order to
        # get the tags which we can't ask for since "api" is `write` privilege.
        # Below line will not work for private packages. For private packages
        # we need to ask for "api" scope.
        for t in paginate(provider(repo).client, get_tags, repo.workspace.slug, repo.slug)
            v = split(t.name, "/")[end]
            if startswith(v, "v")
                v = v[2:end]
            end
            v == string(tag) &&  t.target !== nothing && t.target.hash != commit &&
                return true
        end
    catch err
        @debug("Could not fetch tags")
    end
    false
end
