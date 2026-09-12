module Blocklist

using HTTP
using JSON
using Base64
using Dates
using Logging
import Pkg: TOML

export is_blocked, load_blocklist!

# Maps provider name (e.g. "github") to Set of blocked ID strings.
const BLOCKED_IDS = Dict{String, Set{String}}()
const BLOCKLIST_LOCK = ReentrantLock()
const LAST_FETCH = Ref{DateTime}(DateTime(0))

"""
    load_blocklist!(config::Dict)

Fetch the blocklist from the configured GitHub repo and update the in-memory cache.
The blocklist file is expected to be TOML-formatted with a `[[blocked]]` array of tables,
each having an `id` field (the immutable platform ID) and a `provider` field.

Entries can block individual users OR organizations/repo owners. GitHub users and orgs
share the same ID namespace, so an org ID works the same way as a user ID. Registrator
checks both the requesting user's ID and the repository owner's ID against the blocklist.

Example blocklist.toml:

    # To find a GitHub user or org ID:  curl https://api.github.com/users/NAME
    # To find a GitLab user's ID:       curl https://gitlab.com/api/v4/users?username=NAME
    # To find a GitLab group's ID:      curl https://gitlab.com/api/v4/groups/NAME
    # To find a Bitbucket user's UUID:  curl https://api.bitbucket.org/2.0/users/NAME
    #
    # Or use: scripts/lookup_user_id.sh NAME [github|gitlab|bitbucket]

    # Block a user
    [[blocked]]
    provider = "github"
    id = 12345678
    username = "spammer1"           # for human reference only
    reason = "AI-generated spam"

    # Block an organization (prevents registration of any repo owned by this org)
    [[blocked]]
    provider = "github"
    id = 87654321
    username = "spam-org"
    reason = "organization used for spam packages"

Falls back silently (fail-open) if the repo is unreachable or the file is malformed.
"""
function load_blocklist!(config::Dict)
    repo = get(config, "blocklist_repo", "")
    isempty(repo) && return
    file = get(config, "blocklist_file", "blocklist.toml")
    # Use a dedicated blocklist token if provided, otherwise fall back to the
    # main GitHub token. The token must have read access to the blocklist repo.
    token = get(config, "blocklist_token", "")
    if isempty(token)
        token = get(get(config, "github", Dict()), "token", "")
    end
    isempty(token) && return

    # Fetch outside the lock so that slow/stalled network requests don't block
    # all is_blocked() callers. Only hold the lock for the in-memory swap.
    new_blocked = nothing
    try
        headers = [
            "Authorization" => "Bearer $token",
            "Accept" => "application/vnd.github.v3+json",
            "User-Agent" => "Registrator.jl",
        ]
        url = "https://api.github.com/repos/$repo/contents/$file"
        resp = HTTP.get(url; headers=headers, status_exception=false)
        if resp.status != 200
            @warn "Failed to fetch blocklist" status=resp.status repo=repo file=file
            return
        end
        data = JSON.parse(String(resp.body))
        content = String(base64decode(replace(get(data, "content", ""), "\n" => "")))
        toml = TOML.parse(content)
        new_blocked = Dict{String, Set{String}}()
        for entry in get(toml, "blocked", [])
            id = get(entry, "id", nothing)
            provider = get(entry, "provider", nothing)
            (id === nothing || provider === nothing) && continue
            provider_key = lowercase(string(provider))
            ids = get!(Set{String}, new_blocked, provider_key)
            push!(ids, string(id))
        end
    catch ex
        # Log only the exception type and message, not the full exception object,
        # because HTTP errors may include request headers containing the auth token.
        @warn "Failed to load blocklist, allowing all users" error=sprint(showerror, ex)
        return
    end

    lock(BLOCKLIST_LOCK) do
        empty!(BLOCKED_IDS)
        merge!(BLOCKED_IDS, new_blocked)
        LAST_FETCH[] = now(UTC)
    end
    total = sum(length, values(new_blocked); init=0)
    @info "Blocklist loaded" count=total
end

function maybe_refresh!(config::Dict)
    repo = get(config, "blocklist_repo", "")
    isempty(repo) && return
    ttl = get(config, "blocklist_cache_ttl", 300)
    if (now(UTC) - LAST_FETCH[]).value / 1000 > ttl
        load_blocklist!(config)
    end
end

"""
    is_blocked(provider::AbstractString, user_id, config::Dict) -> Bool

Check whether a user ID on the given provider is on the blocklist.
`provider` should be `"github"`, `"gitlab"`, or `"bitbucket"`.
The `user_id` can be any type (integer, string, UUID) — it is converted to
a string for comparison. Refreshes the cached blocklist if the TTL has expired.
Returns `false` (fail-open) on any error or if the blocklist is not configured.
"""
function is_blocked(provider::AbstractString, user_id, config::Dict)
    repo = get(config, "blocklist_repo", "")
    isempty(repo) && return false

    maybe_refresh!(config)

    provider_key = lowercase(provider)
    id_str = string(user_id)
    blocked = lock(BLOCKLIST_LOCK) do
        id_str in get(BLOCKED_IDS, provider_key, Set{String}())
    end
    if blocked
        @info "Blocked user attempted registration" provider=provider_key user_id=id_str
    end
    return blocked
end

end # module
