# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    r.method == "POST" || return json(405; error="Method not allowed")

    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return json(400; error="Missing or invalid state cookie")
    end
    u = USERS[state]

    return register_common(u.forge, display_user(u.user))
end
