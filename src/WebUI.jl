"""
Required environment variables:

- DISABLED_FORGES: Space-delimited string of hosts to not use, e.g. "github gitlab"
- EXTRA_FORGES: Optional path to a Julia file that adds entries to FORGES.

GitHub settings, if GitHub is not disabled:
- GITHUB_API_TOKEN
- GITHUB_CLIENT_ID
- GITHUB_CLIENT_SECRET
- GITHUB_API_URL: URL of the GitHub instance's API. Only set if it's not the default.
- GITHUB_AUTH_URL: OAuth authentication URL. Only set if it's not the default.
- GITHUB_TOKEN_URL: OAuth token exchange URL. Only set if it's not the default.

GitLab settings, if GitLab is not disabled:
- GITLAB_API_TOKEN
- GITLAB_CLIENT_ID
- GITLAB_CLIENT_SECRET
- GITLAB_API_URL: URL of the GitLab instance's API. Only set if it's not the default.
- GITLAB_AUTH_URL: OAuth authentication URL. Only set if it's not the default.
- GITLAB_TOKEN_URL: OAuth token exchange URL. Only set if it's not the default.

 Web server settings:
- IP: IP address to use, or "localhost".
- PORT: Port to use. e.g. "4000".
- SERVER_URL: Full URL, e.g. "http://localhost:4000".

Registry settings:
- REGISTRY_URL: URL to the target registry.
- REGISTRY_HOST: Host of the registry repo, e.g. "github" or "gitlab".
  You only need to set this if your URL doesn't contain either of those strings.
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

const ROUTER = HTTP.Router()

const ROUTE_INDEX = "/"
const ROUTE_AUTH = "/auth"
const ROUTE_CALLBACK = "/callback"
const ROUTE_SELECT = "/select"
const ROUTE_REGISTER = "/register"

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

const PAGE_SELECT = """
    <form action="$ROUTE_REGISTER" method="post">
    URL of package to register: <input type="text" size="50" name="package">
    <br>
    <input type="submit" value="Submit">
    </form>
    """

# a supported provider whose hosted repositories can be registered.
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

# The target registry.
struct Registry{F <: GitForge.Forge, R}
    forge::F
    repo::R
    url::String
end

# U is a User type, e.g. GitHub.User.
struct User{U, F <: GitForge.Forge}
    user::U
    forge::F
end

const FORGES = Dict{String, Forge}()
const REGISTRY = Ref{Registry}()
const USERS = TTL{String, User}(Hour(1))

# Helpers.

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

# Split a repo path into its owner and name.
function splitrepo(url::AbstractString)
    pieces = split(HTTP.URI(url).path, "/"; keepempty=false)
    owner = join(pieces[1:end-1], "/")
    name = pieces[end]
    return owner, name
end

# Get the callback URL with the provider parameter.
callback_url(p::AbstractString) =
    string(ENV["SERVER_URL"], ROUTE_CALLBACK, "?provider=", HTTP.escapeuri(p))

# Get a query string parameter from a request.
getquery(r::HTTP.Request, key::AbstractString, default="") =
    get(HTTP.queryparams(HTTP.URI(r.target)), key, default)

# Get a cookie from a request.
function getcookie(r::HTTP.Request, key::AbstractString, default="")
    cookies = HTTP.cookies(r)
    ind = findfirst(c -> c.name == key, cookies)
    return ind === nothing ? default : cookies[ind].value
end

# Return an HTML response.
function html(body::AbstractString)
    doc = TEMPLATE
    doc = replace(doc, "{{body}}" => body)
    doc = replace(doc, "{{registry}}" => REGISTRY[].url)
    return HTTP.Response(200, ["Content-Type" => "text/html"]; body=doc)
end

# Helpers specific to step 5

# Look up a repository.
getrepo(::GitLabAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(FORGES["gitlab"].client, owner, name)
getrepo(f::GitHubAPI, owner::AbstractString, name::AbstractString) =
    @gf get_repo(f, owner, name)

# Check for a user's authorization to release a package.
# The criteria is simply whether the user is a collaborator for user-owned repos,
# or whether they're an organization member for organization-owned repos.
isauthorized(u, repo) = false
function isauthorized(u::User{GitHub.User}, repo::GitHub.Repo)
    repo.private && return false
    hasauth = @gf if repo.organization === nothing
        is_collaborator(u.forge, repo.owner.login, repo.name, u.user.login)
    else
        is_member(u.forge, repo.organization.login, u.user.login)
    end
    return something(hasauth, false)
end
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

# Routes.

# Step 1: Home page prompts login.
function index(::HTTP.Request)
    links = map(collect(FORGES)) do p
        link = p.first
        name = p.second.name
        """<a href="$ROUTE_AUTH?provider=$link">Log in to $name</a>"""
    end
    return html(join(links, "<br>"))
end

# Step 2: Redirect to provider.
function auth(r::HTTP.Request)
    forgekey = getquery(r, "provider")
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

    forgekey = getquery(r, "provider")
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

# Step 4: Select a package.
select(::HTTP.Request) = html(PAGE_SELECT)

# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return html("Missing or invalid state cookie")
    end
    u = USERS[state]

    # Parse the form data.
    form = Dict(map(p -> map(HTTP.unescapeuri, split(p, "=")), split(String(r.body), "&")))
    package = form["package"]
    isempty(package) && return html("Package URL was not provided")
    occursin("://", package) || (package = "https://$package")

    # Get the repo, then check for authorization.
    owner, name = splitrepo(package)
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

HTTP.@register ROUTER "GET" ROUTE_INDEX index
HTTP.@register ROUTER "GET" ROUTE_AUTH auth
HTTP.@register ROUTER "GET" ROUTE_CALLBACK callback
HTTP.@register ROUTER "GET" ROUTE_SELECT select
HTTP.@register ROUTER "POST" ROUTE_REGISTER register

# Entrypoint.

function main()
    disabled = split(get(ENV, "DISABLED_FORGES", ""))
    if !in("github", disabled)
        FORGES["github"] = Forge(;
            name="GitHub",
            client=GitHubAPI(;
                url=get(ENV, "GITHUB_API_URL", GitHub.DEFAULT_URL),
                token=Token(ENV["GITHUB_API_TOKEN"]),
            ),
            client_id=ENV["GITHUB_CLIENT_ID"],
            client_secret=ENV["GITHUB_CLIENT_SECRET"],
            auth_url=get(ENV, "GITHUB_AUTH_URL", "https://github.com/login/oauth/authorize"),
            token_url=get(ENV, "GITHUB_TOKEN_URL", "https://github.com/login/oauth/access_token"),
            scope="public_repo",
        )
    end
    if !in("gitlab", disabled)
        FORGES["gitlab"] = Forge(;
            name="GitLab",
            client=GitLabAPI(;
                url=get(ENV, "GITLAB_API_URL", GitLab.DEFAULT_URL),
                token=PersonalAccessToken(ENV["GITLAB_API_TOKEN"]),
            ),
            client_id=ENV["GITLAB_CLIENT_ID"],
            client_secret=ENV["GITLAB_CLIENT_SECRET"],
            auth_url=get(ENV, "GITLAB_AUTH_URL", "https://gitlab.com/oauth/authorize"),
            token_url=get(ENV, "GITLAB_TOKEN_URL", "https://gitlab.com/oauth/token"),
            scope="read_user",
            include_state=false,
            token_type=PersonalAccessToken,
        )
    end
    haskey(ENV, "EXTRA_FORGES") && include(ENV["EXTRA_FORGES"])

    # Look up the registry.
    url = ENV["REGISTRY_URL"]
    k = get(ENV, "REGISTRY_HOST") do
        if occursin("github", url)
            "github"
        elseif occursin("gitlab", url)
            "gitlab"
        end
    end
    haskey(FORGES, k) || error("Unsupported registry host")
    forge = FORGES[k].client
    owner, name = splitrepo(url)
    repo = @gf get_repo(forge, owner, name)
    repo === nothing && error("Registry lookup failed")
    REGISTRY[] = Registry(forge, repo, url)

    ip = ENV["IP"] == "localhost" ? Sockets.localhost : ENV["IP"]
    port = parse(Int, ENV["PORT"])
    @info "Serving" ip port
    HTTP.serve(ROUTER, ip, port; readtimeout=0)
end

end
