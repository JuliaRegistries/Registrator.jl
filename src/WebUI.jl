"""
Required environment variables:

- GITLAB_API_TOKEN: A personal access token with "api" scope.
- GITLAB_CLIENT_ID
- GITLAB_CLIENT_SECRET
- GITHUB_CLIENT_ID
- GITHUB_CLIENT_SECRET
- IP: IP address to use, or "localhost".
- PORT: Port to use. e.g. 4000.
- SERVER_URL: Full URL, e.g. http://localhost:4000.
- DEFAULT_REGISTRY: URL to default registry, e.g. https://github.com/JuliaRegistries/General
"""
module WebUI

using ..Registrator

using Base64
using Dates
using GitForge, GitForge.GitHub, GitForge.GitLab
using HTTP
using JSON2
using Pkg
using Sockets
using TimeToLive

const ROUTE_INDEX = "/"
const ROUTE_AUTH = "/auth"
const ROUTE_CALLBACK = "/callback"
const ROUTE_SELECT = "/select"
const ROUTE_REGISTER = "/register"

# We should be able to use the authenticated user's GitLab client,
# but GitLab requires full API permissions for practically everything.
const gitlab = GitLabAPI(; token=PersonalAccessToken(ENV["GITLAB_API_TOKEN"]))

const FORGES = Dict(
    "github" => (
        client_id=ENV["GITHUB_CLIENT_ID"],
        client_secret=ENV["GITHUB_CLIENT_SECRET"],
        auth_url="https://github.com/login/oauth/authorize",
        token_url="https://github.com/login/oauth/access_token",
        redirect_uri=string(ENV["SERVER_URL"], ROUTE_CALLBACK, "/github"),
        scope="public_repo",
        include_state=true,
        Forge=GitHubAPI,
        Token=Token,
    ),
    "gitlab" => (
        client_id=ENV["GITLAB_CLIENT_ID"],
        client_secret=ENV["GITLAB_CLIENT_SECRET"],
        auth_url="https://gitlab.com/oauth/authorize",
        token_url="https://gitlab.com/oauth/token",
        redirect_uri=string(ENV["SERVER_URL"], ROUTE_CALLBACK, "/gitlab"),
        scope="read_user",
        include_state=false,
        Forge=GitLabAPI,
        Token=OAuth2Token,
    ),
)

# U is a User type, e.g. GitHub.User.
struct User{U, F <: GitForge.Forge}
    user::U
    forge::F
end
const USERS = TTL{String, User}(Hour(1))

# Run some GitForge function, warning on error but still returning the value.
macro gf(ex::Expr)
    quote
        let result = $(esc(ex))
            GitForge.exception(result) === nothing ||
                @warn "API request failed" exception=GitForge.exception(result)
            GitForge.value(result)
        end
    end
end

# Get the forge type from a request whose path ends in the forge name, e.g. "github".
getforge(r::HTTP.Request) = FORGES[split(HTTP.URI(r.target).path, "/")[end]]

# Get a query string parameter from a request.
getquery(r::HTTP.Request, key::AbstractString, default="") =
    get(HTTP.queryparams(HTTP.URI(r.target)), key, default)

# Get a cookie from a request.
function getcookie(r::HTTP.Request, key::AbstractString, default="")
    cookies = HTTP.cookies(r)
    ind = findfirst(c -> c.name == key, cookies)
    return ind === nothing ? default : cookies[ind].value
end

const TEMPLATE = """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Registrator</title>
      </head>
      <body>
        <h1><a href=$ROUTE_INDEX>Registrator</a></h1>
        <br>
        {{body}}
      </body>
    </html>
    """

# Return an HTML response.
function html(body::AbstractString)
    doc = replace(TEMPLATE, "{{body}}" => body)
    return HTTP.Response(200, ["Content-Type" => "text/html"]; body=doc)
end

const PAGE_INDEX = """
    <a href="$ROUTE_AUTH/github">Log in to GitHub</a>
    <br>
    <a href="$ROUTE_AUTH/gitlab">Log in to GitLab</a>
    """

# Step 1: Home page prompts login.
index(::HTTP.Request) = html(PAGE_INDEX)

# Step 2: Redirect to provider.
function auth(r::HTTP.Request)
    forge = getforge(r)
    state = String(rand('a':'z', 32))
    return HTTP.Response(307, [
        "Set-Cookie" => String(HTTP.Cookie("state", state; path="/"), false),
        "Location" => forge.auth_url * "?" * HTTP.escapeuri(Dict(
            :response_type => :code,
            :client_id => forge.client_id,
            :redirect_uri => forge.redirect_uri,
            :scope => forge.scope,
            :state => state,
        )),
    ])
end

# Step 3: OAuth callback.
function callback(r::HTTP.Request)
    state = getcookie(r, "state")
    if isempty(state) || state != getquery(r, "state")
        @error "Bad state parameter"
        return html("Bad state parameter")
    end

    forge = getforge(r)
    query = Dict(
        :client_id => forge.client_id,
        :client_secret => forge.client_secret,
        :redirect_uri => forge.redirect_uri,
        :code => getquery(r, "code"),
        :grant_type => "authorization_code",
    )
    forge.include_state && (query[:state] = state)
    resp = HTTP.post(
        forge.token_url,
        [
            "Accept" => "application/json",
            "User-Agent" => "Registrator.jl",
        ];
        query=query,
    )
    token = JSON2.read(IOBuffer(resp.body)).access_token
    api = forge.Forge(; token=forge.Token(token))
    USERS[state] = User(@gf(get_user(api)), api)
    return HTTP.Response(308, ["Location" => ROUTE_SELECT])
end

const DEFAULT_REGISTRY = ENV["DEFAULT_REGISTRY"]
const PAGE_SELECT = """
    <form action="$ROUTE_REGISTER">
    URL of package to register: <input type="text" name="package">
    <br>
    URL of registry to target: <input type="text" name="registry" value="$DEFAULT_REGISTRY">
    <br>
    <input type="submit" value="Submit">
    </form>
    """

# Step 4: Select a package.
select(::HTTP.Request) = html(PAGE_SELECT)

# Look up a repository.
getrepo(::GitLabAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(gitlab, owner, name)
getrepo(f::GitHubAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(f, owner, name)

# This covers the case where the user and repo come from different forges.
isauthorized(u, repo) = false

# The next two cases check if the repo owner is an organization.
# If it is, check for membership. Otherwise, check for collaborator status.
function isauthorized(u::User{GitHub.User}, repo::GitHub.Repo)
    repo.private && return false
    hasauth = @gf if repo.organization === nothing
        is_collaborator(u.forge, repo.owner.login, repo.name, u.user.login)
    else
        is_member(u.forge, repo.organization.login, u.user.login)
    end
    return something(hasauth, false)
end

# Check for a user's authorization to release a package.
# The criteria is simply whether the user is a collaborator for user-owned repos,
# or whether they're an organization member for organization-owned repos.
function isauthorized(u::User{GitLab.User}, repo::GitLab.Project)
    repo.visibility == "private" && return false
    hasauth = @gf if repo.namespace == "user"
        is_member(gitlab, repo.namespace.full_path, u.user.id)
    else
        is_collaborator(gitlab, repo.owner.username, repo.name, u.user.id)
    end
    return something(hasauth, false)
end

# Get the raw Project.toml text from a repository.
function gettoml(f::GitHubAPI, repo::GitHub.Repo)
    fc = @gf get_file_contents(f, repo.owner.login, repo.name, "Project.toml")
    return fc === nothing ? nothing : String(base64decode(strip(fc.content)))
end

function gettoml(::GitLabAPI, repo::GitLab.Project)
    fc = @gf get_file_contents(gitlab, repo.id, "Project.toml"; ref=repo.default_branch)
    return fc === nothing ? nothing : String(base64decode(fc.content))
end

# Get a repo's clone URL.
cloneurl(r::GitHub.Repo) = r.clone_url
cloneurl(r::GitLab.Project) = r.http_url_to_repo

# Get a repo's tree hash.
function treesha(f::GitHubAPI, r::GitHub.Repo)
    branch = @gf get_branch(f, r.owner.login, r.name, r.default_branch)
    return branch === nothing ? nothing : branch.commit.commit.tree.sha
end

# GitLab's API does not provide the tree hash anywhere.
function treesha(::GitLabAPI, r::GitLab.Project)
    url = cloneurl(r)
    return try
        mktempdir() do dir
            dest = joinpath(dir, r.name)
            run(`git clone $url $dest`)
            match(r"tree (.*)", readchomp(`git -C $dest show HEAD --format=raw`))[1]
        end
    catch
        nothing
    end
end

# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return html("Missing state cookie")
    end
    u = USERS[state]

    registry = getquery(r, "registry")
    package = getquery(r, "package")
    occursin("://", package) || (package = "https://$package")

    # GitLab organizations can be nested, i.e. foo/bar.
    pieces = split(HTTP.URI(package).path, "/"; keepempty=false)
    owner = join(pieces[1:end-1], "/")
    name = pieces[end]

    # Get the repo, then check for authorization.
    repo = getrepo(u.forge, owner, name)
    isauthorized(u, repo) ||
        return html("Unauthorized to release this package")

    # Get the Project.toml, and make sure it has a version.
    toml = gettoml(u.forge, repo)
    toml === nothing && return html("Project.toml was not found")
    m = match(r"version = \"(.*)\"", toml)
    m === nothing && return html("Project.toml did not contain a version")
    try
        VersionNumber(m[1])
    catch
        return html("Version <b>$(m[1])</b> is invalid")
    end

    url = cloneurl(repo)
    project = Pkg.Types.read_project(IOBuffer(toml))
    tree = treesha(u.forge, repo)
    tree === nothing && return html("Looking up the tree hash failed")
    branch = Registrator.register(url, project, tree; registry=registry)
    return if branch.error === nothing
        @error "Registration error: " * branch.error
        html("Registration failed")
    else
        # TODO: Make PR.
        html("Registered!")
    end
end

const ROUTER = HTTP.Router()

HTTP.@register ROUTER "GET" ROUTE_INDEX index
HTTP.@register ROUTER "GET" "$ROUTE_AUTH/*" auth
HTTP.@register ROUTER "GET" "$ROUTE_CALLBACK/*" callback
HTTP.@register ROUTER "GET" ROUTE_SELECT select
HTTP.@register ROUTER "GET" ROUTE_REGISTER register

const IP = ENV["IP"] == "localhost" ? Sockets.localhost : ENV["IP"]
const PORT = parse(Int, ENV["PORT"])

main() = HTTP.serve(ROUTER, IP, PORT)

end
