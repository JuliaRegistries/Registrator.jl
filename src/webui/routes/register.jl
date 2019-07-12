# Step 5: Register the package (maybe).
function register(r::HTTP.Request)
    r.method == "POST" || return json(405; error="Method not allowed")

    state = getcookie(r, "state")
    if isempty(state) || !haskey(USERS, state)
        return json(400; error="Missing or invalid state cookie")
    end
    u = USERS[state]

    # Extract the form data.
    form = parseform(String(r.body))
    package = get(form, "package", "")
    isempty(package) && return json(400; error="Package URL was not provided")
    occursin("://", package) || (package = "https://$package")
    match(r"https?://.*\..*/.*/.*", package) === nothing && return json(400; error="Package URL is invalid")
    ref = get(form, "ref", "")
    isempty(ref) && return json(400; error="Branch was not provided")
    notes = get(form, "notes", "")

    # Get the repo, then check for authorization.
    owner, name = splitrepo(package)
    repo = getrepo(u.forge, owner, name)
    repo === nothing && return json(400; error="Repository was not found")
    isauthorized(u, repo) || return json(400; error="Unauthorized to release this package")

    # Get the (Julia)Project.toml, and make sure it is valid.
    toml = gettoml(u.forge, repo, ref)
    toml === nothing && return json(400; error="(Julia)Project.toml was not found")
    project = try
        Pkg.Types.read_project(IOBuffer(toml))
    catch e
        @error "Reading project from (Julia)Project.toml failed"
        println(get_backtrace(e))
        return json(400; error="(Julia)Project.toml is invalid")
    end
    for k in [:name, :uuid, :version]
        getfield(project, k) === nothing && return json(400; error="In (Julia)Project.toml, `$k` is missing or invalid")
    end

    commit = getcommithash(u.forge, repo, ref)
    commit === nothing && return json(500, error="Looking up the commit hash failed")

    if istagwrong(u.forge, repo, project.version, commit)
        return json(400; error="Tag with a different commit already exists for the version mentioned in (Julia)Project.toml")
    end

    # Register the package,
    tree = gettreesha(u.forge, repo, ref)
    tree === nothing && return json(500, error="Looking up the tree hash failed")
    regdata = RegistrationData(project, tree, repo, u.user, ref, commit, notes)
    REGISTRATIONS[commit] = RegistrationState("Please wait...", :pending)
    put!(event_queue, regdata)
    return json(; message="Registration in progress...", id=commit)
end
