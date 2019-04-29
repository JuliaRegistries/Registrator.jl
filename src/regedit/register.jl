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

const julia_uuid = "1222c4b2-2114-5bfd-aeef-88e4692bbb3e"

struct RegBranch
    name::String
    version::VersionNumber
    branch::String

    metadata::Dict{String,Any} # "error", "warning", kind etc.

    function RegBranch(pkg::Pkg.Types.Project, branch::String)
        new(pkg.name, pkg.version, branch, Dict{String,Any}())
    end
end

function write_registry(registry_path::String, reg::RegistryData)
    open(registry_path, "w") do io
        TOML.print(io, reg)
    end
end

# error in regbr.metadata["errors"]
# warning in regbr.metadata["warning"]
# version labels for the PR in in regbr.metadata["labels"]
function check_version!(regbr::RegBranch, existing::Vector{VersionNumber}, ver::VersionNumber)
    @assert issorted(existing)
    if isempty(existing)
        push!(get!(regbr.metadata, "labels", String[]), "new package")
        if !(ver in [v"0.0.1", v"0.1", v"1"])
            regbr.metadata["warning"] =
                """This looks like a new registration that registers version $ver.
                Ideally, you should register an initial release with 0.0.1, 0.1.0 or 1.0.0 version numbers"""
        end
        return regbr
    else
        idx = searchsortedlast(existing, ver)
        if idx <= 0
            regbr.metadata["error"] = "Version $ver less than least existing version $(existing[1])"
            return regbr
        end

        prv = existing[idx]
        if ver == prv
            regbr.metadata["error"] = "Version $ver already exists"
            return regbr
        end
        nxt = if ver.major != prv.major
            push!(get!(regbr.metadata, "labels", String[]), "major release")
            VersionNumber(prv.major+1, 0, 0)
        elseif ver.minor != prv.minor
            push!(get!(regbr.metadata, "labels", String[]), "minor release")
            VersionNumber(prv.major, prv.minor+1, 0)
        else
            push!(get!(regbr.metadata, "labels", String[]), "patch release")
            VersionNumber(prv.major, prv.minor, prv.patch+1)
        end
        if ver > nxt
            regbr.metadata["warning"] = "Version $ver skips over $nxt"
            return regbr
        end
    end

    return regbr
end

findpackageerror(name::String, uuid::Base.UUID, regdata::Array{RegistryData}) =
    findpackageerror(name, string(uuid), regdata)

function findpackageerror(name::String, u::String, regdata::Array{RegistryData})
    for _registry_data in regdata
        if haskey(_registry_data.packages, u)
            name_in_reg = _registry_data.packages[u]["name"]
            if name_in_reg != name
                return "Error in Project.toml: UUID $u refers to package '$name_in_reg' in registry but Project.toml has '$name'"
            end
            return nothing
        end
    end

    if haskey(BUILTIN_PKGS, name)
        if BUILTIN_PKGS[name] != u
            return "Error in Project.toml: UUID $u for package $name should be $(BUILTIN_PKGS[k])"
        end
    else
        return "Error in Project.toml: Package '$name' with UUID: $u not found in registry or stdlib"
    end

    nothing
end

import Pkg.Types: VersionRange, VersionBound, VersionSpec, compress_versions

function versionrange(lo::VersionBound, hi::VersionBound)
    lo.n < hi.n && lo.t == hi.t && (lo = hi)
    return VersionRange(lo, hi)
end

# monkey patch existing compress_versions function
# (the same in more recent versions of Julia)
"""
    compress_versions(pool::Vector{VersionNumber}, subset::Vector{VersionNumber})
Given `pool` as the pool of available versions (of some package) and `subset` as some
subset of the pool of available versions, this function computes a `VersionSpec` which
includes all versions in `subset` and none of the versions in its complement.
"""
function compress_versions(pool::Vector{VersionNumber}, subset::Vector{VersionNumber})
    subset = sort(subset) # must copy, we mutate this
    complement = sort!(setdiff(pool, subset))
    ranges = VersionRange[]
    @label again
    isempty(subset) && return VersionSpec(ranges)
    a = first(subset)
    for b in reverse(subset)
        a.major == b.major || continue
        for m = 1:3
            lo = VersionBound((a.major, a.minor, a.patch)[1:m]...)
            for n = 1:3
                hi = VersionBound((b.major, b.minor, b.patch)[1:n]...)
                r = versionrange(lo, hi)
                if !any(v in r for v in complement)
                    filter!(!in(r), subset)
                    push!(ranges, r)
                    @goto again
                end
            end
        end
    end
end

function compress_versions(pool::Vector{VersionNumber}, subset)
    compress_versions(pool, filter(in(subset), pool))
end

"""
    register(package_repo, pkg, tree_hash; registry, registry_deps, push, gitconfig)

Register the package at `package_repo` / `tree_hash` in `registry`.
Returns a `RegEdit.RegBranch` which contains information about the registration and/or any
errors or warnings that occurred.

# Arguments

* `package_repo::String`: the git repository URL for the package to be registered
* `pkg::Pkg.Types.Project`: the parsed Project.toml file for the package to be registered
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

    # return object
    regbr = RegBranch(pkg, branch)

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
            if package_data["name"] != pkg.name
                err = "Changing package names not supported yet"
                @debug(err)
                regbr.metadata["error"] = err
                return regbr
            end
            package_path = joinpath(registry_path, package_data["path"])
            repo = TOML.parsefile(joinpath(package_path, "Package.toml"))["repo"]
            if repo != package_repo
                err = "Changing package repo URL not allowed"
                @debug(err)
                regbr.metadata["error"] = err
                return regbr
            end
            regbr.metadata["kind"] = "New version"
        else
            @debug("Package with UUID: $uuid not found in registry, checking if UUID was changed")
            for (k, v) in registry_data.packages
                if v["name"] == pkg.name
                    err = "Changing UUIDs is not allowed"
                    @debug(err)
                    regbr.metadata["error"] = err
                    return regbr
                end
            end

            @debug("Creating directory for new package $(pkg.name)")
            package_path = joinpath(registry_path, package_relpath(registry_data, pkg))
            mkpath(package_path)

            @debug("Adding package UUID to registry")
            push!(registry_data, pkg)
            write_registry(registry_file, registry_data)
            regbr.metadata["kind"] = "New package"
        end

        # update package data: package file
        @debug("update package data: package file")
        package_info = Dict("name" => pkg.name,
                            "uuid" => string(pkg.uuid),
                            "repo" => package_repo)
        package_file = joinpath(package_path, "Package.toml")
        open(package_file, "w") do io
            TOML.print(io, package_info; sorted=true,
                by = x -> x == "name" ? 1 : x == "uuid" ? 2 : 3)
        end

        # update package data: versions file
        @debug("update package data: versions file")
        versions_file = joinpath(package_path, "Versions.toml")
        versions_data = isfile(versions_file) ? TOML.parsefile(versions_file) : Dict()
        versions = sort!([VersionNumber(v) for v in keys(versions_data)])

        check_version!(regbr, versions, pkg.version)
        if get(regbr.metadata, "error", nothing) !== nothing
            return regbr
        end

        version_info = Dict{String,Any}("git-tree-sha1" => string(tree_hash))
        versions_data[string(pkg.version)] = version_info

        open(versions_file, "w") do io
            TOML.print(io, versions_data; sorted=true, by=x->VersionNumber(x))
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
        regdata = [registry_data; registry_deps_data]
        for (k, v) in pkg.deps
            err = findpackageerror(k, v, regdata)
            if err !== nothing
                @debug(err)
                regbr.metadata["error"] = err
                return regbr
            end
        end

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
                    regbr.metadata["error"] = err
                    return regbr
                end
            catch ex
                if isa(ex, ArgumentError)
                    err = "Error in `[compat]`: $(ex.msg)"
                    @debug(err)
                    regbr.metadata["error"] = err
                    return regbr
                else
                    rethrow(ex)
                end
            end
        end

        @debug("update package data: compat file")
        compat_file = joinpath(package_path, "Compat.toml")
        if isfile(compat_file)
            compat_data = Pkg.Compress.load(compat_file)
        else
            compat_data = Dict()
        end

        d = Dict()
        for (n,v) in pkg.compat
            spec = Pkg.Types.semver_spec(v)
            if n == "julia"
                uuidofdep = julia_uuid
            else
                indeps = haskey(pkg.deps, n)
                inextras = haskey(pkg.extras, n)

                if indeps
                    uuidofdep = string(pkg.deps[n])
                elseif inextras
                    uuidofdep = string(pkg.extras[n])
                else
                    err = "Package $n mentioned in `[compat]` but not found in `[deps]` or `[extras]`"
                    @debug(err)
                    regbr.metadata["error"] = err
                    return regbr
                end

                err = findpackageerror(n, uuidofdep, regdata)
                if err !== nothing
                    @debug(err)
                    regbr.metadata["error"] = err
                    return regbr
                end

                if inextras && !indeps
                    @debug("$n is a test-only dependency; omitting from Compat.toml")
                    continue
                end
            end

            regpaths = [registry_path; registry_deps_paths]
            versionsfileofdep = nothing
            for i=1:length(regdata)
                if haskey(regdata[i].packages, uuidofdep)
                    pathofdep = regdata[i].packages[uuidofdep]["path"]
                    versionsfileofdep = joinpath(regpaths[i], pathofdep, "Versions.toml")
                    break
                end
            end
            pool = map(VersionNumber, [keys(TOML.parsefile(versionsfileofdep))...])
            ranges = compress_versions(pool, filter(in(spec), pool)).ranges
            d[n] = length(ranges) == 1 ? string(ranges[1]) : map(string, ranges)
        end
        compat_data[pkg.version] = d

        Pkg.Compress.save(compat_file, compat_data)

        reg_pkgs = Pkg.Display.status(Pkg.Types.Context(),
                                      [Pkg.PackageSpec("Registrator",
                                                       Base.UUID("4418983a-e44d-11e8-3aec-9789530b3b3e"))])
        if length(reg_pkgs) == 0
            reg_commit = "unknown"
        else
            reg_commit = reg_pkgs[1].new.hash
            if reg_commit === nothing    # Registrator is dev'd
                reg_commit = LibGit2.head(Pkg.dir("Registrator"))
            end
        end

        # commit changes
        @debug("commit changes")
        message = """
        $(regbr.metadata["kind"]): $(pkg.name) v$(pkg.version)

        UUID: $(pkg.uuid)
        Repo: $(package_repo)
        Tree: $(string(tree_hash))

        Registrator commit: $(reg_commit)
        """
        run(`$git add -- $package_path`)
        run(`$git add -- $registry_file`)
        run(`$git commit -qm $message`)

        # push -f branch to remote
        @debug("push -f branch to remote")
        push && run(`$git push -q -f -u origin $branch`)

        clean_registry = false
        return regbr
    finally
        if clean_registry
            @debug("cleaning up possibly inconsistent registry", registry_path=showsafe(registry_path), err=showsafe(err))
            rm(registry_path; recursive=true, force=true)
        end
    end
end
