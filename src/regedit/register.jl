"""
Given a remote repo URL and a git tree spec, get a `Project` object
for the project file in that tree and a hash string for the tree.
"""
# function get_project(remote_url::AbstractString, tree_spec::AbstractString)
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

    function RegBranch(pkg::Pkg.Types.Project, branch::AbstractString)
        new(pkg.name, pkg.version, branch, Dict{String,Any}())
    end
end

get_backtrace(ex) = sprint(Base.showerror, ex, catch_backtrace())

function write_registry(registry_path::AbstractString, reg::RegistryData)
    open(registry_path, "w") do io
        TOML.print(io, reg)
    end
end

# error in regbr.metadata["errors"]
# warning in regbr.metadata["warning"]
# version labels for the PR in in regbr.metadata["labels"]
function check_version!(regbr::RegBranch, existing::Vector{VersionNumber})
    ver = regbr.version
    if ver == v"0"
        regbr.metadata["error"] = "Package version must be greater than 0.0.0"
        return regbr
    end

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

findpackageerror(name::AbstractString, uuid::Base.UUID, regdata::Array{RegistryData}) =
    findpackageerror(name, string(uuid), regdata)

function findpackageerror(name::AbstractString, u::AbstractString, regdata::Array{RegistryData})
    for _registry_data in regdata
        if haskey(_registry_data.packages, u)
            name_in_reg = _registry_data.packages[u]["name"]
            if name_in_reg != name
                return "Error in (Julia)Project.toml: UUID $u refers to package '$name_in_reg' in registry but Project.toml has '$name'"
            end
            return nothing
        end
    end

    if haskey(BUILTIN_PKGS, name)
        if BUILTIN_PKGS[name] != u
            return "Error in (Julia)Project.toml: UUID $u for package $name should be $(BUILTIN_PKGS[k])"
        end
    else
        return "Error in (Julia)Project.toml: Package '$name' with UUID: $u not found in registry or stdlib"
    end

    nothing
end

import Pkg.Types: VersionRange, VersionBound, VersionSpec

function versionrange(lo::VersionBound, hi::VersionBound)
    lo.t == hi.t && (lo = hi)
    return VersionRange(lo, hi)
end

# Code copied from Pkg found in dev julia (Current version is 1.1)
# TODO: Remove after moving to julia 1.2
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

import Pkg.Compress.load_versions

function compress(path::AbstractString, uncompressed::Dict,
    versions::Vector{VersionNumber} = load_versions(path))
    inverted = Dict()
    for (ver, data) in uncompressed, (key, val) in data
        val isa TOML.TYPE || (val = string(val))
        push!(get!(inverted, key => val, VersionNumber[]), ver)
    end
    compressed = Dict()
    for ((k, v), vers) in inverted
        for r in compress_versions(versions, sort!(vers)).ranges
            get!(compressed, string(r), Dict{String,Any}())[k] = v
        end
    end
    return compressed
end

function save(path::AbstractString, uncompressed::Dict,
    versions::Vector{VersionNumber} = load_versions(path))
    compressed = compress(path, uncompressed)
    open(path, write=true) do io
        TOML.print(io, compressed, sorted=true)
    end
end

# ---- End of code copied from Pkg

function find_package_in_registry(pkg::Pkg.Types.Project,
                                  package_repo::AbstractString,
                                  registry_file::AbstractString,
                                  registry_path::AbstractString,
                                  registry_data::RegistryData,
                                  regbr::RegBranch)
    uuid = string(pkg.uuid)
    if haskey(registry_data.packages, uuid)
        package_data = registry_data.packages[uuid]
        if package_data["name"] != pkg.name
            err = "Changing package names not supported yet"
            @debug(err)
            regbr.metadata["error"] = err
            return nothing, regbr
        end
        package_path = joinpath(registry_path, package_data["path"])
        repo = TOML.parsefile(joinpath(package_path, "Package.toml"))["repo"]
        if repo != package_repo
            err = "Changing package repo URL not allowed, please submit a pull request with the URL change to the target registry and retry."
            @debug(err)
            regbr.metadata["error"] = err
            return nothing, regbr
        end
        regbr.metadata["kind"] = "New version"
    else
        @debug("Package with UUID: $uuid not found in registry, checking if UUID was changed")
        for (k, v) in registry_data.packages
            if v["name"] == pkg.name
                err = "Changing UUIDs is not allowed"
                @debug(err)
                regbr.metadata["error"] = err
                return nothing, regbr
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

    return package_path, regbr
end

function update_package_file(pkg::Pkg.Types.Project,
                             package_repo::AbstractString,
                             package_path::AbstractString)
    package_info = Dict("name" => pkg.name,
                        "uuid" => string(pkg.uuid),
                        "repo" => package_repo)
    package_file = joinpath(package_path, "Package.toml")
    open(package_file, "w") do io
        TOML.print(io, package_info; sorted=true,
            by = x -> x == "name" ? 1 : x == "uuid" ? 2 : 3)
    end
    nothing
end

function update_versions_file(pkg::Pkg.Types.Project,
                              package_path::AbstractString,
                              regbr::RegBranch,
                              tree_hash::AbstractString)
    versions_file = joinpath(package_path, "Versions.toml")
    versions_data = isfile(versions_file) ? TOML.parsefile(versions_file) : Dict()
    versions = sort!([VersionNumber(v) for v in keys(versions_data)])

    check_version!(regbr, versions)
    if get(regbr.metadata, "error", nothing) !== nothing
        return regbr
    end

    version_info = Dict{String,Any}("git-tree-sha1" => string(tree_hash))
    versions_data[string(pkg.version)] = version_info

    open(versions_file, "w") do io
        TOML.print(io, versions_data; sorted=true, by=x->VersionNumber(x))
    end
    nothing
end

function update_deps_file(pkg::Pkg.Types.Project,
                          package_path::AbstractString,
                          regbr::RegBranch,
                          regdata::Vector{RegistryData})
    if pkg.name in keys(pkg.deps)
        err = "Package $(pkg.name) mentions itself in `[deps]`"
        @debug(err)
        regbr.metadata["error"] = err
        return regbr
    end

    deps_file = joinpath(package_path, "Deps.toml")
    if isfile(deps_file)
        deps_data = Pkg.Compress.load(deps_file)
    else
        deps_data = Dict()
    end

    @debug("Verifying package name and uuid in deps")
    for (k, v) in pkg.deps
        err = findpackageerror(k, v, regdata)
        if err !== nothing
            @debug(err)
            regbr.metadata["error"] = err
            return regbr
        end
    end

    deps_data[pkg.version] = pkg.deps
    save(deps_file, deps_data)
    nothing
end

function update_compat_file(pkg::Pkg.Types.Project,
                            package_path::AbstractString,
                            regbr::RegBranch,
                            regdata::Vector{RegistryData},
                            regpaths::Vector{String})
    err = nothing
    for (p, v) in pkg.compat
        try
            ver = Pkg.Types.semver_spec(v)
            if p == "julia" && any(map(x->!isempty(intersect(Pkg.Types.VersionRange("0-0.6"),x)), ver.ranges))
                err = "Julia version < 0.7 not allowed in `[compat]`"
                @debug(err)
                break
            end
        catch ex
            if isdefined(ex, :msg)
                err = "Error in `[compat]`: $(ex.msg)"
                @debug(err)
                break
            else
                rethrow(ex)
            end
        end
    end

    if err !== nothing
        regbr.metadata["error"] = err
        return regbr
    end

    @debug("update package data: compat file")
    compat_file = joinpath(package_path, "Compat.toml")
    if isfile(compat_file)
        compat_data = Pkg.Compress.load(compat_file)
    else
        compat_data = Dict()
    end

    d = Dict()
    err = nothing
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
                break
            end

            err = findpackageerror(n, uuidofdep, regdata)
            if err !== nothing
                @debug(err)
                break
            end

            if inextras && !indeps
                @debug("$n is a test-only dependency; omitting from Compat.toml")
                continue
            end
        end

        versionsfileofdep = nothing
        for i=1:length(regdata)
            if haskey(regdata[i].packages, uuidofdep)
                pathofdep = regdata[i].packages[uuidofdep]["path"]
                versionsfileofdep = joinpath(regpaths[i], pathofdep, "Versions.toml")
                break
            end
        end
        # the call to map(versionrange, ) can be removed
        # once Pkg is updated to a version including
        # https://github.com/JuliaLang/Pkg.jl/pull/1181
        ranges = map(r->versionrange(r.lower, r.upper), spec.ranges)
        ranges = VersionSpec(ranges).ranges # this combines joinable ranges
        d[n] = length(ranges) == 1 ? string(ranges[1]) : map(string, ranges)
    end

    if err !== nothing
        regbr.metadata["error"] = err
        return regbr
    end

    compat_data[pkg.version] = d

    save(compat_file, compat_data)
    nothing
end

function get_registrator_tree_sha()
    regtreesha = nothing
    reg_pkgs = Pkg.Display.status(Pkg.Types.Context(),
                   [Pkg.PackageSpec("Registrator", Base.UUID("4418983a-e44d-11e8-3aec-9789530b3b3e"))])
    if !isempty(reg_pkgs)
        regtreesha = reg_pkgs[1].new.hash
    end
    if regtreesha === nothing
        regpath = abspath(joinpath(@__DIR__, "..", ".."))
        if isdir(joinpath(regpath, ".git"))
            regtreesha = LibGit2.head(regpath)
        else
            regtreesha = "unknown"
        end
    end

    return regtreesha
end

"""
    register(package_repo, pkg, tree_hash; registry, registry_deps, push, gitconfig)

Register the package at `package_repo` / `tree_hash` in `registry`.
Returns a `RegEdit.RegBranch` which contains information about the registration and/or any
errors or warnings that occurred.

# Arguments

* `package_repo::AbstractString`: the git repository URL for the package to be registered
* `pkg::Pkg.Types.Project`: the parsed (Julia)Project.toml file for the package to be registered
* `tree_hash::AbstractString`: the tree hash (not commit hash) of the package revision to be registered

# Keyword Arguments

* `registry::AbstractString="$DEFAULT_REGISTRY_URL"`: the git repository URL for the registry
* `registry_deps::Vector{String}=[]`: the git repository URLs for any registries containing
    packages depended on by `pkg`
* `push::Bool=false`: whether to push a registration branch to `registry` for consideration
* `gitconfig::Dict=Dict()`: dictionary of configuration options for the `git` command
"""
function register(
    package_repo::AbstractString, pkg::Pkg.Types.Project, tree_hash::AbstractString;
    registry::AbstractString = DEFAULT_REGISTRY_URL,
    registry_deps::Vector{<:AbstractString} = AbstractString[],
    push::Bool = false,
    force_reset::Bool = true,
    branch::String = registration_branch(pkg),
    cache::RegistryCache=REGISTRY_CACHE,
    gitconfig::Dict = Dict()
)
    # get info from package registry
    @debug("get info from package registry")
    package_repo = GitTools.normalize_url(package_repo)

    # return object
    regbr = RegBranch(pkg, branch)

    # get up-to-date clone of registry
    @debug("get up-to-date clone of registry")
    registry = GitTools.normalize_url(registry)
    registry_repo = get_registry(registry; gitconfig=gitconfig, force_reset=force_reset, cache=cache)
    registry_path = LibGit2.path(registry_repo)

    isempty(registry_deps) || @debug("get up-to-date clones of registry dependencies")
    registry_deps_paths = map(registry_deps) do registry
        LibGit2.path(get_registry(GitTools.normalize_url(registry); gitconfig=gitconfig, force_reset=force_reset, cache=cache))
    end

    clean_registry = true
    err = nothing
    try
        # branch registry repo
        @debug("branch registry repo")
        git = gitcmd(registry_path, gitconfig)
        run(pipeline(`$git checkout -f master`; stdout=devnull))
        run(pipeline(`$git branch -f $branch`; stdout=devnull))
        run(pipeline(`$git checkout -f $branch`; stdout=devnull))

        # find package in registry
        @debug("find package in registry")
        registry_file = joinpath(registry_path, "Registry.toml")
        registry_data = parse_registry(registry_file)
        package_path, regbr = find_package_in_registry(pkg, package_repo,
                                                       registry_file, registry_path,
                                                       registry_data, regbr)
        package_path === nothing && return regbr

        # update package data: package file
        @debug("update package data: package file")
        update_package_file(pkg, package_repo, package_path)

        # update package data: versions file
        @debug("update package data: versions file")
        r = update_versions_file(pkg, package_path, regbr, tree_hash)
        r === nothing || return r

        # update package data: deps file
        @debug("update package data: deps file")
        registry_deps_data = map(registry_deps_paths) do registry_path
            parse_registry(joinpath(registry_path, "Registry.toml"))
        end
        regdata = [registry_data; registry_deps_data]
        r = update_deps_file(pkg, package_path, regbr, regdata)
        r === nothing || return r

        # update package data: compat file
        @debug("check compat section")
        regpaths = [registry_path; registry_deps_paths]
        r = update_compat_file(pkg, package_path, regbr, regdata, regpaths)
        r === nothing || return r

        regtreesha = get_registrator_tree_sha()

        # commit changes
        @debug("commit changes")
        message = """
        $(regbr.metadata["kind"]): $(pkg.name) v$(pkg.version)

        UUID: $(pkg.uuid)
        Repo: $(package_repo)
        Tree: $(string(tree_hash))

        Registrator tree SHA: $(regtreesha)
        """
        run(pipeline(`$git add -- $package_path`; stdout=devnull))
        run(pipeline(`$git add -- $registry_file`; stdout=devnull))
        run(pipeline(`$git commit -m $message`; stdout=devnull))

        # push -f branch to remote
        if push
            @debug("push -f branch to remote")
            run(pipeline(`$git push -f -u origin $branch`; stdout=devnull))
        else
            @debug("skipping git push")
        end

        clean_registry = false
    catch ex
        println(get_backtrace(ex))
        regbr.metadata["error"] = "Unexpected error in registration"
    finally
        if clean_registry
            @debug("cleaning up possibly inconsistent registry", registry_path=showsafe(registry_path), err=showsafe(err))
            rm(registry_path; recursive=true, force=true)
        end
    end
    return regbr
end

struct RegisterParams
    package_repo::AbstractString
    pkg::Pkg.Types.Project
    tree_sha::AbstractString
    registry::AbstractString
    registry_deps::Vector{<:AbstractString}
    push::Bool
    gitconfig::Dict

    function RegisterParams(package_repo::AbstractString,
                            pkg::Pkg.Types.Project,
                            tree_sha::AbstractString;
                            registry::AbstractString=DEFAULT_REGISTRY_URL,
                            registry_deps::Vector{<:AbstractString}=[],
                            push::Bool=false,
                            gitconfig::Dict=Dict())
        new(package_repo, pkg, tree_sha,
            registry, registry_deps,
            push, gitconfig)
    end
end

register(regp::RegisterParams) = register(regp.package_repo, regp.pkg, regp.tree_sha;
                                          registry=regp.registry, registry_deps=regp.registry_deps,
                                          push=regp.push, gitconfig=regp.gitconfig)
