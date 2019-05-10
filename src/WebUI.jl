module WebUI

using ..Registrator: RegEdit, pull_request_contents

using Base64
using Dates
using GitForge, GitForge.GitHub, GitForge.GitLab
using HTTP
using JSON
using Mux
using Pkg, Pkg.TOML
using Sockets
using TimeToLive

# Not const since they can be changed if $ROUTE_PREFIX is set.
ROUTE_INDEX = "/"
ROUTE_AUTH = "/auth"
ROUTE_CALLBACK = "/callback"
ROUTE_SELECT = "/select"
ROUTE_REGISTER = "/register"

const DOCS = "https://github.com/JuliaRegistries/Registrator.jl/blob/master/README.web.md#usage-for-package-maintainers"

const CONFIG = Dict{String, Any}()

# A supported provider whose hosted repositories can be registered.
Base.@kwdef struct Provider{F <: GitForge.Forge}
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
    clone::String
    deps::Vector{String}
    enable_patch_notes::Bool
end

# U is a User type, e.g. GitHub.User.
struct User{U, F <: GitForge.Forge}
    user::U
    forge::F
end

const PROVIDERS = Dict{String, Provider}()
const REGISTRY = Ref{Registry}()
const USERS = TTL{String, User}(Hour(1))

###########
# Helpers #
###########

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
    string(CONFIG["server_url"], ROUTE_CALLBACK, "?provider=", HTTP.escapeuri(p))

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
html(body::AbstractString) = html(200, body)
function html(status::Int, body::AbstractString)
    registry = REGISTRY[].url
    doc = """
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
                line-height: 1.8;
                color: #333;
              }
              a {
                color: inherit;
              }
              h3, h4 {
                color: #555;
              }
            </style>
          </head>
          <body>
            <h1><a href="$ROUTE_INDEX">Registrator</a></h1>
            <h4>Registry URL: <a href="$registry" target="_blank">$registry</a></h3>
            <h3>Click <a href="$DOCS" target="_blank">here</a> for usage instructions</h3>
            <br>
            $body
          </body>
        </html>
        """
    return HTTP.Response(status, ["Content-Type" => "text/html"]; body=doc)
end

##############################
# Helpers specific to step 5 #
##############################

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

# Parse an HTML form.
function parseform(s::AbstractString)
    # In forms, '+' represents a space.
    pairs = split(replace(s, "+" => " "), "&")
    return Dict(map(p -> map(strip ∘ HTTP.unescapeuri, split(p, "=")), pairs))
end

##########
# Routes #
##########

# Step 1: Home page prompts login.
function index(::HTTP.Request)
    links = map(collect(PROVIDERS)) do p
        link = p.first
        name = p.second.name
        """<a href="$ROUTE_AUTH?provider=$link">Log in to $name</a>"""
    end
    return html(join(links, "<br>"))
end

# Step 2: Redirect to provider.
function auth(r::HTTP.Request)
    pkey = getquery(r, "provider")
    provider = get(PROVIDERS, pkey, nothing)
    provider === nothing && return html(400, "Requested uknown OAuth provider")

    # If the user has already authenticated, skip.
    state = getcookie(r, "state")
    if !isempty(state) && haskey(USERS, state)
        F = typeof(USERS[state].forge)
        if pkey == "github" && F === GitHubAPI || pkey == "gitlab" && F === GitLabAPI
            # TODO: This does not support custom providers.
            return HTTP.Response(307, ["Location" => ROUTE_SELECT])
        end
    end

    state = String(rand('a':'z', 32))
    return HTTP.Response(307, [
        "Set-Cookie" => String(HTTP.Cookie("state", state; path="/"), false),
        "Location" => provider.auth_url * "?" * HTTP.escapeuri(Dict(
            :response_type => "code",
            :client_id => provider.client_id,
            :redirect_uri => callback_url(pkey),
            :scope => provider.scope,
            :state => state,
        )),
    ])
end

# Step 3: OAuth callback.
function callback(r::HTTP.Request)
    state = getcookie(r, "state")
    (isempty(state) || state != getquery(r, "state")) && return html(400, "Invalid state")

    pkey = getquery(r, "provider")
    provider = get(PROVIDERS, pkey, nothing)
    provider === nothing && return html(400, "Invalid callback URL")

    query = Dict(
        :client_id => provider.client_id,
        :client_secret => provider.client_secret,
        :redirect_uri => callback_url(pkey),
        :code => getquery(r, "code"),
        :grant_type => "authorization_code",
    )
    provider.include_state && (query[:state] = state)

    resp = HTTP.post(
        provider.token_url;
        headers=["Accept" => "application/json", "User-Agent" => "Registrator.jl"],
        query=query,
    )
    token = JSON.parse(String(resp.body))["access_token"]

    client = typeof(provider.client)(;
        url=GitForge.base_url(provider.client),
        token=provider.token_type(token),
        has_rate_limits=GitForge.has_rate_limits(provider.client, identity),
    )
    USERS[state] = User(@gf(get_user(client)), client)

    return HTTP.Response(308, ["Location" => ROUTE_SELECT])
end

# Step 4: Select a package.
function select(::HTTP.Request)
    body = """
        <script>
        function disableButton() {
          var button = document.getElementById("submitButton");
          button.disabled = true;
          button.value = "Please wait...";
        }
        </script>
        <form action="$ROUTE_REGISTER" method="post" onsubmit="disableButton()">
        URL of package to register: <input type="text" size="50" name="package">
        <br>
        Git reference (branch/tag/commit): <input type="text" size="20" name="ref" value="master">
        <br>
        """

    if REGISTRY[].enable_patch_notes
        body *= """
            Patch notes (optional):
            <br>
            <textarea cols="80" rows="10" name="notes"></textarea>
            <br>
            """
    end

    body *= """
        <input id="submitButton" type="submit" value="Submit">
        </form>
        """

    return html(body)
end

# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    r.method == "POST" || return html(405, "Method not allowed")

    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return html(400, "Missing or invalid state cookie")
    end
    u = USERS[state]

    # Extract the form data.
    form = parseform(String(r.body))
    package = get(form, "package", "")
    isempty(package) && return html(400, "Package URL was not provided")
    occursin("://", package) || (package = "https://$package")
    match(r"https?://.*\..*/.*/.*", package) === nothing && return html(400, "Package URL is invalid")
    ref = get(form, "ref", "")
    isempty(ref) && return html(400, "Branch was not provided")
    notes = get(form, "notes", "")

    # Get the repo, then check for authorization.
    owner, name = splitrepo(package)
    repo = getrepo(u.forge, owner, name)
    repo === nothing && return html(400, "Repository was not found")
    isauthorized(u, repo) || return html(400, "Unauthorized to release this package")

    # Get the Project.toml, and make sure it is valid.
    toml = gettoml(u.forge, repo, ref)
    toml === nothing && return html(400, "Project.toml was not found")
    project = try
        Pkg.Types.read_project(IOBuffer(toml))
    catch
        return html(400, "Project.toml is invalid")
    end
    for k in [:name, :uuid, :version]
        getfield(project, k) === nothing && return html(400, "Package $k is invalid")
    end

    commit = getcommithash(u.forge, repo, ref)
    commit === nothing && return html(500, "Looking up the commit hash failed")

    # Register the package,
    clone = cloneurl(repo)
    project = Pkg.Types.read_project(IOBuffer(toml))
    tree = gettreesha(u.forge, repo, ref)
    tree === nothing && return html(500, "Looking up the tree hash failed")
    branch = RegEdit.register(
        clone, project, tree;
        registry=REGISTRY[].clone, registry_deps=REGISTRY[].deps, push=true,
    )

    return if get(branch.metadata, "error", nothing) === nothing
        title, body = pull_request_contents(;
            registration_type=get(branch.metadata, "kind", ""),
            package=project.name,
            repo=web_url(repo),
            user=display_user(u.user),
            gitref=ref,
            version=project.version,
            commit=commit,
            patch_notes=notes,
        )

        # Make the PR.
        pr = @gf make_registration_request(REGISTRY[], branch.branch, title, body)
        pr === nothing && return html(500, "Registration failed: Making pull request failed")

        url = web_url(pr)
        html("""Registry PR successfully created, see it <a href="$url" target="_blank">here</a>!""")
    else
        html(500, "Registration failed: " * branch.metadata["error"])
    end
end

##############
# Entrypoint #
##############

function init_providers()
    if  haskey(CONFIG, "github")
        github = CONFIG["github"]
        PROVIDERS["github"] = Provider(;
            name="GitHub",
            client=GitHubAPI(;
                url=get(github, "api_url", GitHub.DEFAULT_URL),
                token=Token(github["token"]),
                has_rate_limits=!get(github, "disable_rate_limits", false),
            ),
            client_id=github["client_id"],
            client_secret=github["client_secret"],
            auth_url=get(github, "auth_url", "https://github.com/login/oauth/authorize"),
            token_url=get(github, "token_url", "https://github.com/login/oauth/access_token"),
            scope="public_repo",
        )
    end

    if haskey(CONFIG, "gitlab")
        gitlab = CONFIG["gitlab"]
        PROVIDERS["gitlab"] = Provider(;
            name="GitLab",
            client=GitLabAPI(;
                url=get(gitlab, "api_url", GitLab.DEFAULT_URL),
                token=PersonalAccessToken(gitlab["token"]),
                has_rate_limits=!get(gitlab, "disable_rate_limits", false),
            ),
            client_id=gitlab["client_id"],
            client_secret=gitlab["client_secret"],
            auth_url=get(gitlab, "auth_url", "https://gitlab.com/oauth/authorize"),
            token_url=get(gitlab, "token_url", "https://gitlab.com/oauth/token"),
            scope="read_user",
            include_state=false,
            token_type=OAuth2Token,
        )
    end

    haskey(CONFIG, "extra_providers") && include(CONFIG["extra_providers"])
end

function init_registry()
    url = CONFIG["registry_url"]
    k = get(CONFIG, "registry_provider") do
        if occursin("github", url)
            "github"
        elseif occursin("gitlab", url)
            "gitlab"
        end
    end
    haskey(PROVIDERS, k) || error("Unsupported registry host")
    forge = PROVIDERS[k].client
    owner, name = splitrepo(url)
    repo = @gf get_repo(forge, owner, name)
    repo === nothing && error("Registry lookup failed")
    clone = get(CONFIG, "registry_clone_url", url)
    deps = get(CONFIG, "registry_deps", String[])
    enable_patch_notes = !get(CONFIG, "disable_patch_notes", false)
    REGISTRY[] = Registry(forge, repo, url, clone, deps, enable_patch_notes)
end

for f in [:index, :auth, :callback, :select, :register]
    @eval $f(f::Function, r::HTTP.Request) = f($f(r))
end

error_handler(f::Function, r::HTTP.Request) = try
    f(r)
catch e
    @error "Handler error" route=r.target exception=(e, catch_backtrace())
    html(500, "Server error, sorry!")
end

pathmatch(p::AbstractString, f::Function) = branch(r -> first(split(r.target, "?")) == p, f)

function start_server(ip::IPAddr, port::Int)
    @app server = (
        error_handler,
        pathmatch(ROUTE_INDEX, index),
        pathmatch(ROUTE_AUTH, auth),
        pathmatch(ROUTE_CALLBACK, callback),
        pathmatch(ROUTE_SELECT, select),
        pathmatch(ROUTE_REGISTER, register),
        r -> html(404, "Page not found"),
    )
    return serve(server, ip, port; readtimeout=0)
end

function main(config::AbstractString="config.toml")
    merge!(CONFIG, TOML.parsefile(config)["web"])

    if haskey(CONFIG, "route_prefix")
        for r in [:ROUTE_INDEX, :ROUTE_AUTH, :ROUTE_CALLBACK, :ROUTE_SELECT, :ROUTE_REGISTER]
            @eval $r = CONFIG["route_prefix"] * $r
        end
    end

    init_providers()
    init_registry()

    ip = CONFIG["ip"] == "localhost" ? Sockets.localhost : parse(IPAddr, CONFIG["ip"])
    port = CONFIG["port"]

    task = start_server(ip, port)
    @info "Serving" ip port
    wait(task)
end

end
