auth_href(::Provider{BitbucketAPI}) = "$(ROUTES[:BITBUCKET])/auth"

callback_url(::Provider{BitbucketAPI}) = """$(CONFIG["server_url"])$(ROUTES[:BITBUCKET])/callback"""

function bitbucket(r::HTTP.Request)
    op = split(subtarget(:BITBUCKET, r), r"[/?]")[1]
    println("BITBUCKET: $(op)")
    route(BitbucketAPI, op, r)
end

route(F::Type, service::AbstractString, r::HTTP.Request) = route(Route{F, Symbol(service)}, r)

function route(::Type{Route{F, S}}, r::HTTP.Request) where {F, S}
    println("ACCESSING INVALID ROUTE: $(route)")
    HTTP.Response(503; body="Invalid request")
end

# OAuth Step 2: Redirect to provider.
function route(::Type{Route{BitbucketAPI, :auth}}, r::HTTP.Request)
    # If the user has already authenticated, skip.
    state = getcookie(r, "state")
    if !isempty(state) && haskey(USERS, state)
        USERS[state].forge isa BitbucketAPI &&
            return HTTP.Response(307, ["Location" => ROUTES[:SELECT]])
        # continue if the user was logged into a different service
        # authentication will change their service
    end
    provider = PROVIDERS["bitbucket"]
    state = String(rand('a':'z', 32))
    return HTTP.Response(307, [
        "Set-Cookie" => String(HTTP.Cookie("state", state; path="/"), false),
        "Location" => provider.auth_url * "?" * HTTP.escapeuri(Dict(
            :response_type => "code",
            :client_id => provider.client_id,
        )),
    ])
end

# Step 3: OAuth callback -- sent from the browser via a redirect from Bitbucket
function route(::Type{Route{BitbucketAPI, :callback}}, r::HTTP.Request)
    state = getcookie(r, "state")
    isempty(state) && return html(400, "Invalid state")
    provider = PROVIDERS["bitbucket"]
    query = Dict(
        :code => getquery(r, "code"),
        :grant_type => "authorization_code",
    )
    provider.include_state && (query[:state] = state)
    url = URI(URI(provider.token_url); userinfo="$(provider.client_id):$(provider.client_secret)")
    resp = HTTP.post(
        string(url),
        headers=["Accept" => "application/json", "User-Agent" => "Registrator.jl"],
        HTTP.Form(query)
    )
    token = JSON.parse(String(resp.body))["access_token"]
    client = typeof(provider.client)(;
        url=GitForge.base_url(provider.client),
        token=Bitbucket.JWT(token),
        has_rate_limits=GitForge.has_rate_limits(provider.client, identity),
    )
    USERS[state] = User(@gf(get_user(client)), client)

    return HTTP.Response(308, ["Location" => ROUTES[:SELECT]])
end

# /bitbucket/describe -- Describe OAUTH app to the repository hosting service
# this is for things like putting a Julia Registrator panel in your Bitbucket repo page

#function bbroute(::Type{BB{:describe}}, r::HTTP.Request)
#    json(;
#         key = "julia-registrator",
#         name = "Julia Registrator",
#         description = "The Julia package registration service",
#         vendor =
#             (;
#              name = "Julia Computing",
#              url = "https://4609-2a0d-6fc2-4632-7600-a89e-5244-9885-febc.ngrok.io",
#              ),
#         baseUrl = "https://4609-2a0d-6fc2-4632-7600-a89e-5244-9885-febc.ngrok.io",
#         authentication = (; type = "jwt"),
#         lifecycle =
#             (;
#              installed = "/bitbucket/installed",
#              uninstalled = "/bitbucket/uninstalled",
#              ),
#         scopes = ["account", "repository"],
#         contexts = ["account"],
#         modules =
#             (;
#              oauthConsumer = (; clientId="dCmqMQYcdtN2RsSmBLTPttN2CwQv97sk"),
#              repoPages = [
#                  (;
#                   url = "/bitbucket/repopage?repoUuid={repository.uuid}",
#                   name = (; value = "Registrator Panel"),
#                   location = "org.bitbucket.repository.navigation",
#                   key = "registrator-repo-page",
#                   params = (;),
#                   ),
#              ],
#              ),
#         )
#end
