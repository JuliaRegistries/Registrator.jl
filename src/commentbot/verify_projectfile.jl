using ..Registrator: decodeb64
import RegistryTools

function is_pfile_parseable(c::AbstractString)
    @debug("Checking whether (Julia)Project.toml is non-empty and parseable")
    if length(c) != 0
        try
            TOML.parse(c)
            return true, nothing
        catch ex
            if isa(ex, CompositeException) && isa(ex.exceptions[1], TOML.ParserError)
                err = "Error parsing project file"
                @debug(err)
                return false, err
            else
                rethrow(ex)
            end
        end
    else
        err = "Project file is empty"
        @debug(err)
        return false, err
    end
end

function pfile_hasfields(p::Dict)
    @debug("Checking whether (Julia)Project.toml contains name, uuid and version")
    try
        if p.name === nothing || p.uuid === nothing || p.version === nothing
            err = "Project file should contain name, uuid and version"
            @debug(err)
            return false, err
        elseif !isempty(p.version.prerelease)
            err = "Pre-release version not allowed"
            @debug(err)
            return false, err
        elseif p.version == v"0"
            err = "Package version must be greater than 0.0.0"
            @debug(err)
            return false, err
        end
    catch ex
        err = "Error reading (Julia)Project.toml: $(ex.msg)"
        @debug(err)
        return false, err
    end

    return true, nothing
end

function verify_projectfile_from_sha(reponame, commit_sha; auth=GitHub.AnonymousAuth(), subdir = "")
    project = nothing
    projectfile_found = false
    projectfile_valid = false
    err = nothing
    @debug("Getting gitcommit object for sha")
    gcom = gitcommit(reponame, GitCommit(Dict("sha"=>commit_sha)); auth=auth)
    @debug("Getting tree object for sha")
    recurse = subdir != ""
    t = tree(reponame, Tree(gcom.tree); auth=auth, params = Dict(:recursive => recurse))
    tree_sha = t.sha
    project_files = joinpath.(subdir, Base.project_names)

    for tr in t.tree, file in project_files
        if tr["path"] == subdir
            tree_sha = tr["sha"]
        elseif tr["path"] == file
            projectfile_found = true
            @debug("(Julia)Project file found")

            @debug("Getting projectfile blob")
            if isa(auth, GitHub.AnonymousAuth)
                a = get_user_auth()
            else
                a = auth
            end
            b = blob(reponame, Blob(tr["sha"]); auth=a)

            @debug("Decoding base64 projectfile contents")
            projectfile_contents = decodeb64(b.content)

            @debug("Checking project file validity")
            projectfile_parseable, err = is_pfile_parseable(projectfile_contents)

            if projectfile_parseable
                try
                    project = TOML.parse(projectfile_contents)
                catch ex
                    err = "Failed to read project file"
                    if isdefined(ex, :msg)
                        err = err * ": $(e.msg)"
                    end
                    @error(err)
                end
                if project !== nothing
                    projectfile_valid, err = pfile_hasfields(project)
                end
            end
            break
        end
    end

    return project, tree_sha, projectfile_found, projectfile_valid, err
end
