function extract_form_data(r::HTTP.Request)
    form = parseform(String(r.body))
    package = get(form, "package", "")
    isempty(package) && return "Package URL was not provided"
    occursin("://", package) || (package = "https://$package")
    match(r"https?://.*\..*/.*/.*", package) === nothing && return "Package URL is invalid"
    ref = get(form, "ref", "")
    isempty(ref) && return "Branch was not provided"
    notes = get(form, "notes", "")
    package, ref, notes
end

function get_repo(forge, package::String)
    owner, name = splitrepo(package)
    repo = getrepo(forge, owner, name)
    return repo
end

function check_and_register(forge, repo, ref, notes, userid)
    # Get the (Julia)Project.toml, and make sure it is valid.
    toml = gettoml(forge, repo, ref)
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

    commit = getcommithash(forge, repo, ref)
    commit === nothing && return json(500, error="Looking up the commit hash failed")

    if istagwrong(forge, repo, project.version, commit)
        return json(400; error="Tag with a different commit already exists for the version mentioned in (Julia)Project.toml")
    end

    # Register the package,
    tree = gettreesha(forge, repo, ref)
    tree === nothing && return json(500, error="Looking up the tree hash failed")
    regdata = RegistrationData(project, tree, repo, display_user(u.user), ref, commit, notes)
    REGISTRATIONS[commit] = RegistrationState("Please wait...", :pending)
    put!(event_queue, regdata)
    return json(; message="Registration in progress...", id=commit)
end
