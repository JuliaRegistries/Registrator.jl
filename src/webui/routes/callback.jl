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

    return HTTP.Response(308, ["Location" => ROUTES[:SELECT]])
end
