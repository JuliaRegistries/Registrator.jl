# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    r.method == "POST" || return json(405; error="Method not allowed")

    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return json(400; error="Missing or invalid state cookie")
    end
    u = USERS[state]

    ret = extract_form_data(r)
    ret isa String && return json(400; error=ret)
    package, ref, notes = ret

    repo = getrepo(u.forge, package)
    repo === nothing && return json(400; error="Repository was not found")

    isauthorized(u, repo) || return json(400; error="Unauthorized to release this package")

    return check_and_register(u.forge, repo, ref, notes, display_user(u.user))
end
