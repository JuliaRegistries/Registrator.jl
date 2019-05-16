# Get status of the registration
function status(r::HTTP.Request)
    r.method == "GET" || return json(405; error="Method not allowed")

    # Only allow authenticated users
    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return json(400; error="Missing or invalid state cookie")
    end

    id = getquery(r, "id")
    haskey(REGISTRATIONS, id) || return json(404; state="unknown")
    regstate = REGISTRATIONS[id]
    regstate.state === :pending || delete!(REGISTRATIONS, id)
    return json(; state=regstate.state, message=regstate.msg)
end
