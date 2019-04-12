"""
Return a `GitRepo` object for an up-to-date copy of `registry`.
"""
function get_registry(registry::String; gitconfig::Dict=Dict())
    reg_path(args...) = joinpath("registries", map(string, args)...)
    if haskey(REGISTRIES, registry)
        registry_uuid = REGISTRIES[registry]
        registry_path = reg_path(registry_uuid)
        if !ispath(registry_path)
            LibGit2.clone(registry, registry_path, branch="master")
        else
            # this is really annoying/impossible to do with LibGit2
            git = gitcmd(registry_path, gitconfig)
            run(`$git config remote.origin.url $registry`)
            run(`$git checkout -q -f master`)
            run(`$git fetch -q -P origin master`)
            run(`$git reset -q --hard origin/master`)
        end
    else
        registry_temp = mktempdir(mkpath(reg_path()))
        try
            LibGit2.clone(registry, registry_temp)
            reg = TOML.parsefile(joinpath(registry_temp, "Registry.toml"))
            registry_uuid = REGISTRIES[registry] = UUID(reg["uuid"])
            registry_path = reg_path(registry_uuid)
            rm(registry_path, recursive=true, force=true)
            mv(registry_temp, registry_path)
        finally
            rm(registry_temp, recursive=true, force=true)
        end
    end
    return GitRepo(registry_path)
end

"""
Given a remote repo URL and a git tree spec, get a `Project` object
for the project file in that tree and a hash string for the tree.
"""
# function get_project(remote_url::String, tree_spec::String)
#     # TODO?: use raw file downloads for GitHub/GitLab
#     mktempdir(mkpath("packages")) do tmp
#         # bare clone the package repo
#         @debug("bare clone the package repo")
#         repo = LibGit2.clone(remote_url, joinpath(tmp, "repo"), isbare=true)
#         tree = try
#             LibGit2.GitObject(repo, tree_spec)
#         catch err
#             err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
#             error("$remote_url: git object $(repr(tree_spec)) could not be found")
#         end
#         tree isa LibGit2.GitTree || (tree = LibGit2.peel(LibGit2.GitTree, tree))
#
#         # check out the requested tree
#         @debug("check out the requested tree")
#         tree_path = abspath(tmp, "tree")
#         GC.@preserve tree_path begin
#             opts = LibGit2.CheckoutOptions(
#                 checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
#                 target_directory = Base.unsafe_convert(Cstring, tree_path)
#             )
#             LibGit2.checkout_tree(repo, tree, options=opts)
#         end
#
#         # look for a project file in the tree
#         @debug("look for a project file in the tree")
#         project_file = Pkg.Types.projectfile_path(tree_path)
#         project_file !== nothing && isfile(project_file) ||
#             error("$remote_url: git tree $(repr(tree_spec)) has no project file")
#
#         # parse the project file
#         @debug("parse the project file")
#         project = Pkg.Types.read_project(project_file)
#         project.name === nothing &&
#             error("$remote_url $(repr(tree_spec)): package has no name")
#         project.uuid === nothing &&
#             error("$remote_url $(repr(tree_spec)): package has no UUID")
#         project.version === nothing &&
#             error("$remote_url $(repr(tree_spec)): package has no version")
#
#         return project, string(LibGit2.GitHash(tree))
#     end
# end

struct RegBranch
    name::String
    version::VersionNumber
    branch::String

    warning::Union{Nothing, String}
    error::Union{Nothing, String}

    function RegBranch(pkg::Pkg.Types.Project, branch::String; wa=nothing, er=nothing)
        new(pkg.name, pkg.version, branch, wa, er)
    end
end

function write_registry(io::IO, data::Dict)
    mandatory_keys = ("name", "uuid")
    optional_keys = ("repo",)
    reserved_keys = (mandatory_keys..., optional_keys..., "description", "packages")

    extra_keys = filter(!in(reserved_keys), keys(data))

    for key in mandatory_keys
        println(io, "$key = ", repr(data[key]))
    end

    for key in optional_keys
        if haskey(data, key)
            println(io, "$key = ", repr(data[key]))
        end
    end

    if haskey(data, "description")
        println(io)
        print(io, """
            description = \"\"\"
            $(data["description"])\"\"\"
            """
        )
    end

    for key in extra_keys
        TOML.print(io, Dict(key => data["key"]), sorted=true)
    end

    println(io)
    println(io, "[packages]")
    if haskey(data, "packages")
        for (uuid, data) in sort!(collect(data["packages"]), by=first)
            println(io, uuid, " = { name = ", repr(data["name"]), ", path = ", repr(data["path"]), " }")
        end
    end
end

function write_registry(registry_path::String, data::Dict)
    open(registry_path, "w") do io
        write_registry(io, data)
    end
end

import Base: thismajor, thisminor, nextmajor, nextminor, thispatch, nextpatch, lowerbound

# Returns Tuple (error, warning)
function check_version(existing::Vector{VersionNumber}, ver::VersionNumber)
    if isempty(existing)
        if all([lowerbound(v) <= ver <= v for v in [v"0.0.1", v"0.1", v"1"]])
            return nothing, "This looks like a new registration that registers version $ver. Ideally, you should register an initial release with 0.0.1, 0.1.0 or 1.0.0 version numbers"
        end
    else
        issorted(existing) || (existing = sort(existing))
        idx = searchsortedlast(existing, ver)
        if idx <= 0
            return "Version $ver less than least existing version $(existing[1])", nothing
        end

        prv = existing[idx]
        if ver == prv
            return "Version $ver already exists", nothing
        end
        nxt = thismajor(ver) != thismajor(prv) ? nextmajor(prv) :
              thisminor(ver) != thisminor(prv) ? nextminor(prv) : nextpatch(prv)
        if ver > nxt
            return nothing, "Version $ver skips over $nxt"
        end
    end

    return nothing, nothing
end

"""
Register the package at `package_repo` / `tree_spect` in `registry`.
"""
function register(
    package_repo::String, pkg::Pkg.Types.Project, tree_hash::String;
    registry::String = DEFAULT_REGISTRY,
    registry_deps::Vector{String} = String[],
    push::Bool = false,
    gitconfig::Dict = Dict()
)
    # get info from package registry
    @debug("get info from package registry")
    package_repo = GitTools.normalize_url(package_repo)
    #pkg, tree_hash = get_project(package_repo, tree_spec)
    branch = "register/$(pkg.name)/v$(pkg.version)"

    # get up-to-date clone of registry
    @debug("get up-to-date clone of registry")
    registry = GitTools.normalize_url(registry)
    registry_repo = get_registry(registry; gitconfig=gitconfig)
    registry_path = LibGit2.path(registry_repo)

    isempty(registry_deps) || @debug("get up-to-date clones of registry dependencies")
    registry_deps_paths = map(registry_deps) do registry
        LibGit2.path(get_registry(GitTools.normalize_url(registry); gitconfig=gitconfig))
    end

    clean_registry = true
    err = nothing
    try
        # branch registry repo
        @debug("branch registry repo")
        git = gitcmd(registry_path, gitconfig)
        run(`$git checkout -qf master`)
        run(`$git branch -qf $branch`)
        run(`$git checkout -qf $branch`)

        # find package in registry
        @debug("find package in registry")
        registry_file = joinpath(registry_path, "Registry.toml")
        registry_data = TOML.parsefile(registry_file)

        uuid = string(pkg.uuid)
        if haskey(registry_data["packages"], uuid)
            package_data = registry_data["packages"][uuid]
            if (package_data["name"] != pkg.name)
                err = "Changing package names not supported yet"
                @debug(err)
                return RegBranch(pkg, branch; er=err)
            end
            package_path = joinpath(registry_path, package_data["path"])
        else
            @debug("Package with UUID: $uuid not found in registry, checking if UUID was changed")
            for (k, v) in registry_data["packages"]
                if v["name"] == pkg.name
                    err = "Changing UUIDs is not allowed"
                    @debug(err)
                    return RegBranch(pkg, branch; er=err)
                end
            end

            @debug("Creating directory for new package $(pkg.name)")
            first_letter = uppercase(pkg.name[1])
            package_relpath = joinpath("$first_letter", pkg.name)
            package_path = joinpath(registry_path, package_relpath)
            mkpath(package_path)

            @debug("Adding package UUID to registry")
            registry_data["packages"][uuid] = Dict(
                "name" => pkg.name, "path" => package_relpath
            )
            write_registry(registry_file, registry_data)
        end

        # update package data: package file
        @debug("update package data: package file")
        package_info = filter(((k,v),)->!(v isa Dict), Pkg.Types.destructure(pkg))
        delete!(package_info, "version")
        package_info["repo"] = package_repo
        package_file = joinpath(package_path, "Package.toml")
        write_toml(package_file, package_info)

        # update package data: versions file
        @debug("update package data: versions file")
        versions_file = joinpath(package_path, "Versions.toml")
        versions_data = isfile(versions_file) ? TOML.parsefile(versions_file) : Dict()
        versions = sort!([VersionNumber(v) for v in keys(versions_data)])

        err, wa = check_version(versions, pkg.version)
        if err !== nothing
            return RegBranch(pkg, branch; er=err)
        end

        version_info = Dict{String,Any}("git-tree-sha1" => string(tree_hash))
        versions_data[string(pkg.version)] = version_info

        vnlist = sort([(VersionNumber(k), v) for (k, v) in versions_data])
        vslist = [(string(k), v) for (k, v) in vnlist]

        open(versions_file, "w") do io
            TOML.print(io, OrderedDict(vslist))
        end

        # update package data: deps file
        @debug("update package data: deps file")
        deps_file = joinpath(package_path, "Deps.toml")
        if isfile(deps_file)
            deps_data = Pkg.Compress.load(deps_file)
        else
            deps_data = Dict()
        end

        @debug("Verifying package name and uuid in deps")
        registry_deps_data = map(registry_deps_paths) do registry_path
            TOML.parsefile(joinpath(registry_path, "Registry.toml"))
        end
        for (k, v) in pkg.deps
            u = string(v)

            uuid_found = false
            for _registry_data in [registry_data; registry_deps_data]
                if haskey(_registry_data["packages"], u)
                    uuid_found = true
                    name_in_reg = _registry_data["packages"][u]["name"]
                    if name_in_reg != k
                        err = "Error in `[deps]`: UUID $u refers to package '$name_in_reg' in registry but deps file has '$k'"
                        break
                    end
                    break
                end
            end

            err !== nothing && break
            uuid_found == true && continue

            if haskey(BUILTIN_PKGS, k)
                if BUILTIN_PKGS[k] != u
                    err = "Error in `[deps]`: UUID $u for package $k should be $(BUILTIN_PKGS[k])"
                    break
                end
            else
                err = "Error in `[deps]`: Package '$k' with UUID: $u not found in registry or stdlib"
                break
            end
        end

        err !== nothing && return RegBranch(pkg, branch; er=err)

        deps_data[pkg.version] = pkg.deps
        Pkg.Compress.save(deps_file, deps_data)

        # update package data: compat file
        @debug("check compat section")
        for (p, v) in pkg.compat
            try
                ver = Pkg.Types.semver_spec(v)
                if p == "julia" && any(map(x->!isempty(intersect(Pkg.Types.VersionRange("0-0.6"),x)), ver.ranges))
                    err = "Julia version < 0.7 not allowed in `[compat]`"
                    @debug(err)
                end
            catch ex
                if isa(ex, ArgumentError)
                    err = "Error in `[compat]`: $(ex.msg)"
                    @debug(err)
                else
                    rethrow(ex)
                end
            end
        end

        err !== nothing && return RegBranch(pkg, branch; er=err)

        @debug("update package data: compat file")
        compat_file = joinpath(package_path, "Compat.toml")
        if isfile(compat_file)
            compat_data = Pkg.Compress.load(compat_file)
        else
            compat_data = Dict()
        end
        compat_data[pkg.version] = Dict{String,Any}(n=>Pkg.Types.semver_spec(v) for (n,v) in pkg.compat)
        Pkg.Compress.save(compat_file, compat_data)

        # commit changes
        @debug("commit changes")
        message = """
        New version: $(pkg.name) v$(pkg.version)

        UUID: $(pkg.uuid)
        Repo: $(package_repo)
        Tree: $(string(tree_hash))
        """
        run(`$git add -- $package_path`)
        run(`$git add -- $registry_file`)
        run(`$git commit -qm $message`)

        # push -f branch to remote
        @debug("push -f branch to remote")
        push && run(`$git push -q -f -u origin $branch`)

        clean_registry = false
        return RegBranch(pkg, branch; wa=wa)
    finally
        if clean_registry
            @debug("cleaning up possibly inconsistent registry", registry_path=showsafe(registry_path), err=showsafe(err))
            rm(registry_path; recursive=true, force=true)
        end
    end
end
