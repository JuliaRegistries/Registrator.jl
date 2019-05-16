# # Run some GitForge function, warning on error but still returning the value.
macro gf(ex::Expr)
    quote
        let result = $(esc(ex))
            GitForge.exception(result) === nothing ||
                @warn "API request failed" exception=GitForge.exception(result)
            GitForge.value(result)
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
getrepo(::GitLabAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(PROVIDERS["gitlab"].client, owner, name)
getrepo(f::GitHubAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(f, owner, name)

# Check for a user's authorization to release a package.
# The criteria is simply whether the user is a collaborator for user-owned repos,
# or whether they're an organization member or collaborator for organization-owned repos.
isauthorized(u, repo) = false
function isauthorized(u::User{GitHub.User}, repo::GitHub.Repo)
    repo.private && return false
    hasauth = if repo.organization === nothing
        @gf is_collaborator(u.forge, repo.owner.login, repo.name, u.user.login)
    else
        # First check for organization membership, and fall back to collaborator status.
        ismember = @gf is_member(u.forge, repo.organization.login, u.user.login)
        something(ismember, false) ||
            @gf is_collaborator(u.forge, repo.organization.login, repo.name, u.user.login)
    end
    return something(hasauth, false)
end

function isauthorized(u::User{GitLab.User}, repo::GitLab.Project)
    repo.visibility == "private" && return false
    forge = PROVIDERS["gitlab"].client
    hasauth = if repo.namespace.kind == "user"
        @gf is_collaborator(forge, repo.owner.username, repo.name, u.user.id)
    else
        # Same as above: group membership then collaborator check.
        ismember = @gf is_member(forge, repo.namespace.full_path, u.user.id)
        something(ismember, false) ||
            @gf is_collaborator(u.forge, repo.organization.login, repo.name, u.user.id)
    end
    return something(hasauth, false)
end

# Get the raw Project.toml text from a repository.
function gettoml(f::GitHubAPI, repo::GitHub.Repo, ref::AbstractString)
    fc = @gf get_file_contents(f, repo.owner.login, repo.name, "Project.toml"; ref=ref)
    return fc === nothing ? nothing : String(base64decode(strip(fc.content)))
end

function gettoml(::GitLabAPI, repo::GitLab.Project, ref::AbstractString)
    forge = PROVIDERS["gitlab"].client
    fc = @gf get_file_contents(forge, repo.id, "Project.toml"; ref=ref)
    return fc === nothing ? nothing : String(base64decode(fc.content))
end

function getcommithash(f::GitHubAPI, repo::GitHub.Repo, ref::AbstractString)
    commit = @gf get_commit(f, repo.owner.login, repo.name, ref)
    return commit === nothing ? nothing : commit.sha
end

function getcommithash(f::GitLabAPI, repo::GitLab.Project, ref::AbstractString)
    forge = PROVIDERS["gitlab"].client
    commit = @gf get_commit(forge, repo.id, ref)
    return commit === nothing ? nothing : commit.id
end

# Get a repo's clone URL.
cloneurl(r::GitHub.Repo) = r.clone_url
cloneurl(r::GitLab.Project) = r.http_url_to_repo

# Get a repo's tree hash.
function gettreesha(f::GitHubAPI, r::GitHub.Repo, ref::AbstractString)
    branch = @gf get_branch(f, r.owner.login, r.name, ref)
    return branch === nothing ? nothing : branch.commit.commit.tree.sha
end

function gettreesha(::GitLabAPI, r::GitLab.Project, ref::AbstractString)
    url = cloneurl(r)

    if REGISTRY[] isa Registry{GitLabAPI}
        # For private repositories, we need to insert the token into the URL.
        host = HTTP.URI(url).host
        token = CONFIG["gitlab"]["token"]
        url = replace(url, host => "oauth2:$token@$host")
    end

    return try
        mktempdir() do dir
            dest = joinpath(dir, r.name)
            run(`git clone $url $dest`)
            match(r"tree (.*)", readchomp(`git -C $dest show $ref --format=raw`))[1]
        end
    catch ex
        println(get_backtrace(ex))
        @debug "Exception while getting tree SHA"
        nothing
    end
end

#TODO: Check for existing pull request and update it
# Make the PR to the registry.
function make_registration_request(
    r::Registry{GitLabAPI},
    branch::AbstractString,
    title::AbstractString,
    body::AbstractString,
)
    return create_pull_request(
        r.forge, r.repo.id;
        source_branch=branch,
        target_branch=r.repo.default_branch,
        title=title,
        description=body,
        remove_source_branch=true,
    )
end

function make_registration_request(
    r::Registry{GitHubAPI},
    branch::AbstractString,
    title::AbstractString,
    body::AbstractString,
)
    return create_pull_request(
        r.forge, r.repo.owner.login, r.repo.name;
        head=branch,
        base=r.repo.default_branch,
        title=title,
        body=body,
    )
end

# Get the web URL of various Git things.
web_url(pr::GitHub.PullRequest) = pr.html_url
web_url(mr::GitLab.MergeRequest) = mr.web_url
web_url(u::GitHub.User) = u.html_url
web_url(u::GitLab.User) = u.web_url
web_url(r::GitHub.Repo) = r.html_url
web_url(r::GitLab.Project) = r.web_url

# Get a user's @ mention.
mention(u::GitHub.User) = "@$(u.login)"
mention(u::GitLab.User) = "@$(u.username)"

# Get a user's representation for a registry PR.
# If the registry is from the same provider, mention the user, otherwise use the URL.
display_user(u::U) where U =
    (parentmodule(typeof(REGISTRY[].repo)) === parentmodule(U) ? mention : web_url)(u)
