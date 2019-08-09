# Web API to register with JWT token
function register_jwt(r::HTTP.Request)
    r.method == "POST" || return json(405; error="Method not allowed")

    h = Dict(r.headers)
    haskey(h, "JWT") || return json(400; error="`JWT` not found in headers")
    jwt = JWTs.JWT(; jwt=string(h["JWT"]))
    validate!(jwt, KEYSET, KEYID) || return json(400; error="Invalid JWT")
    c = claims(jwt)
    haskey(c, "userid") || return json(400; error="`userid` not found in JWT")
    userid = c["userid"]

    form = parseform(String(copy(r.body)))
    package = get(form, "package", "")
    if startswith(package, "https://github.com")
        forge = PROVIDERS["github"].client
    elseif startswith(package, "https://gitlab.com")
        forge = PROVIDERS["gitlab"].client
    else
        return json(400; error="Unsupported git service")
    end

    if parentmodule(typeof(REGISTRY[].repo)) === parentmodule(forge)
        u = "@$userid"
    else
        u = joinpath(siteurl(forge), userid)
    end
    return register_common(forge, u)
end
