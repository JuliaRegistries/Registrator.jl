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
            return HTTP.Response(307, ["Location" => ROUTES[:SELECT]])
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
