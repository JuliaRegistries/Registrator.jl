# """
# Given a remote repo URL and a git tree spec, get a `Project` object
# for the project file in that tree and a hash string for the tree.
# """
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

function write_registry(registry_path::String, reg::RegistryData)
    open(registry_path, "w") do io
        TOML.print(io, reg)
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
    register(package_repo, pkg, tree_hash; registry, registry_deps, push, gitconfig)

Register the package at `package_repo` / `tree_hash` in `registry`.
Returns a `RegEdit.RegBranch` which contains information about the registration and/or any
errors or warnings that occurred.

# Arguments

* `package_repo::String`: the git repository URL for the package to be registered
* `pkg::Pkt.Types.Project`: the parsed Project.toml file for the package to be registered
* `tree_hash::String`: the tree hash (not commit hash) of the package revision to be registered

# Keyword Arguments

* `registry::String="$DEFAULT_REGISTRY_URL"`: the git repository URL for the registry
* `registry_deps::Vector{String}=[]`: the git repository URLs for any registries containing
    packages depended on by `pkg`
* `push::Bool=false`: whether to push a registration branch to `registry` for consideration
* `gitconfig::Dict=Dict()`: dictionary of configuration options for the `git` command
"""
function register(
    package_repo::String, pkg::Pkg.Types.Project, tree_hash::String;
    registry::String = DEFAULT_REGISTRY_URL,
    registry_deps::Vector{String} = String[],
    push::Bool = false,
    gitconfig::Dict = Dict()
)
    # get info from package registry
    @debug("get info from package registry")
    package_repo = GitTools.normalize_url(package_repo)
    #pkg, tree_hash = get_project(package_repo, tree_spec)
    branch = registration_branch(pkg)

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
        registry_data = parse_registry(registry_file)

        uuid = string(pkg.uuid)
        if haskey(registry_data.packages, uuid)
            package_data = registry_data.packages[uuid]
            if (package_data["name"] != pkg.name)
                err = "Changing package names not supported yet"
                @debug(err)
                return RegBranch(pkg, branch; er=err)
            end
            package_path = joinpath(registry_path, package_data["path"])
        else
            @debug("Package with UUID: $uuid not found in registry, checking if UUID was changed")
            for (k, v) in registry_data.packages
                if v["name"] == pkg.name
                    err = "Changing UUIDs is not allowed"
                    @debug(err)
                    return RegBranch(pkg, branch; er=err)
                end
            end

            @debug("Creating directory for new package $(pkg.name)")
            package_path = joinpath(registry_path, package_relpath(registry_data, pkg))
            mkpath(package_path)

            @debug("Adding package UUID to registry")
            push!(registry_data, pkg)
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
            parse_registry(joinpath(registry_path, "Registry.toml"))
        end
        for (k, v) in pkg.deps
            u = string(v)

            uuid_found = false
            for _registry_data in [registry_data; registry_deps_data]
                if haskey(_registry_data.packages, u)
                    uuid_found = true
                    name_in_reg = _registry_data.packages[u]["name"]
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
        compat_data[pkg.version] = Dict{String,Any}(n=>[ver for ver in Pkg.Types.semver_spec(v).ranges] for (n,v) in pkg.compat)
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
