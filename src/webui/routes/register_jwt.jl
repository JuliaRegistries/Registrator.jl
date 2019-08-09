# Web API to register with JWT token
function register_jwt(r::HTTP.Request)
    r.method == "POST" || return json(405; error="Method not allowed")

    h = Dict(r.headers)
    haskey(h, "JWT") || return json(400; error="`JWT` not found in headers")
    jwt = JWTs.JWT(; jwt=string(h["JWT"]))
    validate!(jwt, KEYSET, KEYID) || return json(400; error="Invalid JWT")
    c = claims(jwt)
    haskey(c, "email") || return json(400; error="`email` not found in JWT")
    email = c["email"]

    form = parseform(String(copy(r.body)))
    package = get(form, "package", "")
    if startswith(package, "https://github.com")
        forge = PROVIDERS["github"].client
    elseif startswith(package, "https://gitlab.com")
        forge = PROVIDERS["gitlab"].client
    else
        return json(400; error="Unsupported git service")
    end

    ret = extract_form_data(r)
    ret isa String && return json(400; error=ret)
    package, ref, notes = ret

    repo = getrepo(forge, package)
    repo === nothing && return json(400; error="Repository was not found")

    return check_and_register(forge, repo, ref, notes, email)
end
