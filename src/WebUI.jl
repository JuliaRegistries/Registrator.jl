"""
Required environment variables:

- GITLAB_API_TOKEN
- GITLAB_CLIENT_ID
- GITLAB_CLIENT_SECRET
- GITHUB_API_TOKEN
- GITHUB_CLIENT_ID
- GITHUB_CLIENT_SECRET
- IP: IP address to use, or "localhost".
- PORT: Port to use. e.g. 4000.
- SERVER_URL: Full URL, e.g. http://localhost:4000.
- REGISTRY_URL: URL to the target registry.
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

Base.@kwdef struct Forge{F <: GitForge.Forge}
    name::String
    client::F
    client_id::String
    client_secret::String
    auth_url::String
    token_url::String
    scope::String
    include_state::Bool = true
    token_type::Type = typeof(client.token)
end

struct Registry{F <: GitForge.Forge, R}
    forge::F
    repo::R
    url::String
end

const FORGES = Dict{String, Forge}()
const REGISTRY = Ref{Registry}()

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

# Get the last path element of a request.
pathend(r::HTTP.Request) = split(HTTP.URI(r.target).path, "/")[end]

# Get the callback URL with an extra path component.
callback_url(x::AbstractString) = string(ENV["SERVER_URL"], ROUTE_CALLBACK, "/", x)

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
        <style>
        body {
          background-color: #ddd;
          text-align: center;
          margin: auto;
          max-width: 50em;
          font-family: Helvetica, sans-serif;
          line-height: 1.5;
          color: #333;
        }
        a {
          color: inherit;
        }
        h3 {
          color: #555;
        }
        </style>
      </head>
      <body>
        <h1><a href=$ROUTE_INDEX>Registrator</a></h1>
        <h3>Registry URL: <a href="{{registry}}">{{registry}}</a></h3>
        <br>
        {{body}}
      </body>
    </html>
    """

# Return an HTML response.
function html(body::AbstractString)
    doc = TEMPLATE
    doc = replace(doc, "{{body}}" => body)
    doc = replace(doc, "{{registry}}" => REGISTRY[].url)
    return HTTP.Response(200, ["Content-Type" => "text/html"]; body=doc)
end

# Step 1: Home page prompts login.
function index(::HTTP.Request)
    links = map(collect(FORGES)) do p
        link = p.first
        name = p.second.name
        """<a href="$ROUTE_AUTH/$link">Log in to $name</a>"""
    end
    return html(join(links, "<br>"))
end

# Step 2: Redirect to provider.
function auth(r::HTTP.Request)
    forgekey = pathend(r)
    forge = get(FORGES, forgekey, nothing)
    forge === nothing && return html("Requested uknown OAuth provider")

    # If the user has already authenticated, skip.
    # TODO: This doesn't allow a user to register packages
    # from multiple providers in one session.
    state = getcookie(r, "state")
    if !isempty(state) && haskey(USERS, state)
        return HTTP.Response(307, ["Location" => ROUTE_SELECT])
    end

    state = String(rand('a':'z', 32))
    return HTTP.Response(307, [
        "Set-Cookie" => String(HTTP.Cookie("state", state; path="/"), false),
        "Location" => forge.auth_url * "?" * HTTP.escapeuri(Dict(
            :response_type => :code,
            :client_id => forge.client_id,
            :redirect_uri => callback_url(forgekey),
            :scope => forge.scope,
            :state => state,
        )),
    ])
end

# Step 3: OAuth callback.
function callback(r::HTTP.Request)
    state = getcookie(r, "state")
    (isempty(state) || state != getquery(r, "state")) && return html("Invalid state")

    forgekey = pathend(r)
    forge = get(FORGES, forgekey, nothing)
    forge === nothing && return html("Invalid callback URL")

    query = Dict(
        :client_id => forge.client_id,
        :client_secret => forge.client_secret,
        :redirect_uri => callback_url(forgekey),
        :code => getquery(r, "code"),
        :grant_type => "authorization_code",
    )
    forge.include_state && (query[:state] = state)
    resp = HTTP.post(
        forge.token_url;
        headers=["Accept" => "application/json", "User-Agent" => "Registrator.jl"],
        query=query,
    )
    token = JSON2.read(IOBuffer(resp.body)).access_token
    client = typeof(forge.client)(; token=forge.token_type(token))
    USERS[state] = User(@gf(get_user(client)), client)
    return HTTP.Response(308, ["Location" => ROUTE_SELECT])
end

const PAGE_SELECT = """
    <form action="$ROUTE_REGISTER" method="post">
    URL of package to register: <input type="text" size="50" name="package">
    <br>
    <input type="submit" value="Submit">
    </form>
    """

# Step 4: Select a package.
select(::HTTP.Request) = html(PAGE_SELECT)

# Look up a repository.
getrepo(::GitLabAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(FORGES["gitlab"].client, owner, name)
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

# Get the web URL of a pull request.
pr_url(pr::GitHub.PullRequest) = pr.html_url
pr_url(mr::GitLab.MergeRequest) = mr.web_url

# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return html("Missing or invalid state cookie")
    end
    u = USERS[state]

    # Parse the form data.
    form = Dict(map(p -> map(HTTP.unescapeuri, split(p, '=')), split(String(r.body), '&')))
    package = form["package"]
    isempty(package) && return html("Package URL was not provided")
    occursin("://", package) || (package = "https://$package")

    # Get the repo, then check for authorization.
    # GitLab organizations can be nested, i.e. foo/bar.
    pieces = split(HTTP.URI(package).path, "/"; keepempty=false)
    owner = join(pieces[1:end-1], "/")
    name = pieces[end]
    repo = getrepo(u.forge, owner, name)
    repo === nothing && return html("Repository was not found")
    isauthorized(u, repo) || return html("Unauthorized to release this package")

    # Get the Project.toml, and make sure it is valid.
    toml = gettoml(u.forge, repo)
    toml === nothing && return html("Project.toml was not found")
    project = try
        Pkg.Types.read_project(IOBuffer(toml))
    catch
        return html("Project.toml is invalid")
    end
    for k in [:name, :uuid, :version]
        getfield(project, k) === nothing && return html("Package $k is invalid")
    end

    # Register the package,
    clone = cloneurl(repo)
    project = Pkg.Types.read_project(IOBuffer(toml))
    tree = treesha(u.forge, repo)
    tree === nothing && return html("Looking up the tree hash failed")
    branch = Registrator.register(clone, project, tree; registry=REGISTRY[].url)

    if branch.error === nothing
        title = "TODO: Title"
        body = "TODO: Body"

        # Make the PR.
        pr = @gf make_registration_request(REGISTRY[], branch.branch, title, body)
        pr === nothing && return html("Registration failed: Making pull request failed")

        url = pr_url(pr)
        html("""Registry PR successfully created, see it <a href="$url">here</a>!""")
    else
        html("Registration failed: " * branch.error)
    end
end

const ROUTER = HTTP.Router()

HTTP.@register ROUTER "GET" ROUTE_INDEX index
HTTP.@register ROUTER "GET" "$ROUTE_AUTH/*" auth
HTTP.@register ROUTER "GET" "$ROUTE_CALLBACK/*" callback
HTTP.@register ROUTER "GET" ROUTE_SELECT select
HTTP.@register ROUTER "POST" ROUTE_REGISTER register

function main()
    # The config file should populate FORGES.
    include(get(ENV, "REGISTRATOR_CONFIG", joinpath(dirname(@__DIR__), "config.jl")))

    # Look up the registry.
    url = ENV["REGISTRY_URL"]
    k = if occursin("github", url)
        "github"
    elseif occursin("gitlab", url)
        "gitlab"
    else
        error("Unsupported registry host")
    end
    forge = FORGES[k].client
    pieces = split(HTTP.URI(url).path, "/"; keepempty=false)
    owner = join(pieces[1:end-1], "/")
    name = pieces[end]
    repo = @gf get_repo(forge, owner, name)
    repo === nothing && error("Registry lookup failed")
    REGISTRY[] = Registry(forge, repo, url)

    ip = ENV["IP"] == "localhost" ? Sockets.localhost : ENV["IP"]
    port = parse(Int, ENV["PORT"])
    HTTP.serve(ROUTER, ip, port)
end

end
