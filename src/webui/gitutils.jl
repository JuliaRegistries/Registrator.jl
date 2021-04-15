using ..Registrator: decodeb64
using Mocking

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
getrepo(::GitHubAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(PROVIDERS["github"].client, owner, name)


abstract type AuthResult end
struct AuthSuccess <: AuthResult end
struct AuthFailure <: AuthResult
    reason::AbstractString
end

is_success(res::AuthSuccess) = true
is_success(res::AuthFailure) = false

const AUTH_REG_FILE = "authorized_registrars.txt"
const AUTH_FILE_NOT_FOUND_ERROR = "`$AUTH_REG_FILE` was not found in this repository"
const EMAIL_ID_NOT_PUBLIC = "Please make your email ID public in your GitHub/GitLab settings page"
const USER_NOT_IN_AUTH_LIST_ERROR = "Your email ID is not in the $AUTH_REG_FILE of this repository"

get_repo_owner_id(repo::GitLab.Project) = repo.owner === nothing ? nothing : repo.owner.username
get_repo_owner_id(repo::GitHub.Repo) = repo.owner === nothing ? nothing : repo.owner.login

function get_auth_file_content(forge, repo::GitHub.Repo, ref::AbstractString)
    @gf get_file_contents(forge, get_repo_owner_id(repo), repo.name, AUTH_REG_FILE; ref=ref)
end

function get_auth_file_content(forge, repo::GitLab.Project, ref::AbstractString)
    @gf get_file_contents(forge, repo.id, AUTH_REG_FILE; ref=ref)
end

function authorize_user_from_file(
    forge, u::User{T}, repo::Union{GitLab.Project, GitHub.Repo},
    ref::AbstractString
) where T

    fc = @mock get_auth_file_content(forge, repo, ref)
    if fc === nothing
        return AuthFailure(AUTH_FILE_NOT_FOUND_ERROR)
    end
    if u.user.email === nothing || isempty(u.user.email)
        return AuthFailure(EMAIL_ID_NOT_PUBLIC)
    end
    if !(strip(u.user.email) in map(strip, split(decodeb64(fc.content), "\n")))
        return AuthFailure(USER_NOT_IN_AUTH_LIST_ERROR)
    end
    return AuthSuccess()
end

# Check for a user's authorization to release a package.
# The criteria is simply whether the user is a collaborator for user-owned repos,
# or whether they're an organization member or collaborator for organization-owned repos.
isauthorized(u, repo) = AuthFailure("Unkown user type or repo type")
function isauthorized(u::User{GitHub.User}, repo::GitHub.Repo; ref::AbstractString="HEAD")
    if !get(CONFIG, "allow_private", false)
        repo.private && return AuthFailure("Repo $(repo.name) is private")
    end

    if repo.private
        forge = PROVIDERS["github"].client
    else
        forge = u.forge
    end

    if u.user.login == get_repo_owner_id(repo)
        return AuthSuccess()
    elseif get(CONFIG, "authtype", "") == "authfile"
        return authorize_user_from_file(forge, u, repo, ref)
    elseif repo.organization === nothing
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

function isauthorized(u::User{GitLab.User}, repo::GitLab.Project; ref::AbstractString="HEAD")
    if !get(CONFIG, "allow_private", false)
        repo.visibility == "private" && return AuthFailure("Project $(repo.name) is private")
    end

    if repo.visibility == "private"
        forge = PROVIDERS["gitlab"].client
    else
        forge = u.forge
    end

    if u.user.username == get_repo_owner_id(repo)
        return AuthSuccess()
    elseif get(CONFIG, "authtype", "") == "authfile"
        return authorize_user_from_file(forge, u, repo, ref)
    elseif repo.namespace.kind == "user"
        hasauth = @gf @mock is_collaborator(forge, repo.owner.username, repo.name, u.user.id)
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
        if ismember
            return AuthSuccess()
        else
            return AuthFailure("Project $(repo.name) belongs to the group $(repo.namespace.full_path), and user $(u.user.name) is not a member of that group or its parent group(s)")
        end
    end
end

# Get the raw (Julia)Project.toml text from a repository.
function gettoml(::GitHubAPI, repo::GitHub.Repo, ref::AbstractString, subdir::AbstractString)
    forge = PROVIDERS["github"].client
    result = nothing
    for file in Base.project_names
        result = get_file_contents(forge, repo.owner.login, repo.name, joinpath(subdir, file); ref=ref)
        fc = GitForge.value(result)
        fc === nothing || return decodeb64(fc.content)
    end
    @error "Failed to get project file" exception=GitForge.exception(result)
    return nothing
end

function gettoml(::GitLabAPI, repo::GitLab.Project, ref::AbstractString, subdir::AbstractString)
    forge = PROVIDERS["gitlab"].client
    result = nothing
    for file in Base.project_names
        result = get_file_contents(forge, repo.id, joinpath(subdir, file); ref=ref)
        fc = GitForge.value(result)
        fc === nothing || return decodeb64(fc.content)
    end
    @error "Failed to get project file" exception=GitForge.exception(result)
    return nothing
end

function getcommithash(::GitHubAPI, repo::GitHub.Repo, ref::AbstractString)
    forge = PROVIDERS["github"].client
    commit = @gf get_commit(forge, repo.owner.login, repo.name, ref)
    return commit === nothing ? nothing : commit.sha
end

function getcommithash(::GitLabAPI, repo::GitLab.Project, ref::AbstractString)
    forge = PROVIDERS["gitlab"].client
    commit = @gf get_commit(forge, repo.id, ref)
    return commit === nothing ? nothing : commit.id
end

# Get a repo's clone URL.
cloneurl(r::GitHub.Repo, is_ssh::Bool=false) = is_ssh ? r.ssh_url : r.clone_url
cloneurl(r::GitLab.Project, is_ssh::Bool=false) = is_ssh ? r.ssh_url_to_repo : r.http_url_to_repo

function gettreesha(
    r::Union{GitLab.Project, GitHub.Repo},
    ref::AbstractString,
    subdir::AbstractString
)
    url = cloneurl(r)

    # For private repositories, we need to insert the token into the URL.
    host = HTTP.URI(url).host
    token = CONFIG[isa(r, GitLab.Project) ? "gitlab" : "github"]["token"]
    url = replace(url, host => "oauth2:$token@$host")

    return try
        mktempdir() do dir
            dest = joinpath(dir, r.name)
            run(`git clone $url $dest`)

            if isdir(joinpath(dest, subdir))
                readchomp(`git -C $dest rev-parse $ref:$subdir`), ""
            else
                nothing, "The sub-directory $subdir does not exist in this repository"
            end
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
make_registration_request

function make_registration_request(
    r::Registry{GitLabAPI},
    branch::AbstractString,
    title::AbstractString,
    body::AbstractString,
)
    repoid = r.repo.id
    base = r.repo.default_branch
    result = create_pull_request(
        r.forge, repoid;
        source_branch=branch,
        target_branch=base,
        title=title,
        description=body,
        remove_source_branch=true,
    )
    ex = GitForge.exception(result)
    ex === nothing && return result
    resp = GitForge.response(result)
    if !ensure_already_exists(data -> get(data, "message", String[]), resp, 409)
        @error "Exception making registration request" repoid=repoid base=base head=branch
        return result
    end

    prs = get_pull_requests(r.forge, repoid; source_branch=branch, target_branch=base, state="opened")
    val = GitForge.value(prs)
    @assert length(val) == 1
    prid = first(val).iid
    return update_pull_request(r.forge, repoid, prid; title=title, body=body)
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
    result = create_pull_request(
        r.forge, owner, repo;
        head=branch,
        base=base,
        title=title,
        body=body,
    )
    ex = GitForge.exception(result)
    ex === nothing && return result
    resp = GitForge.response(result)
    exists = ensure_already_exists(resp, 422) do data
        map(e -> get(e, "message", ""), get(data, "errors", []))
    end
    if !exists
        @error "Exception making registration request" owner=owner repo=repo base=base head=branch
        return result
    end

    prs = get_pull_requests(r.forge, owner, repo; head="$owner:$branch", base=base, state="open")
    val = GitForge.value(prs)
    @assert length(val) == 1
    prid = first(val).number
    return update_pull_request(r.forge, owner, repo, prid; title=title, body=body)
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

function istagwrong(
    ::GitHubAPI,
    repo::GitHub.Repo,
    tag::VersionNumber,
    commit::String,
)
    result = @gf get_tags(PROVIDERS["github"].client, repo.owner.login, repo.name)

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
    result = @gf get_tags(PROVIDERS["gitlab"].client, project.id)

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
