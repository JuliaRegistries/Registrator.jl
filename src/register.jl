"""
Return a `GitRepo` object for an up-to-date copy of `registry`.
"""
function get_registry(registry::String)
    reg_path(args...) = joinpath("registries", map(string, args)...)
    if haskey(REGISTRIES, registry)
        registry_uuid = REGISTRIES[registry]
        registry_path = reg_path(registry_uuid)
        if !ispath(registry_path)
            LibGit2.clone(registry, registry_path, branch="master")
        else
            # this is really annoying/impossible to do with LibGit2
            git = `git -C $registry_path`
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

"""
Write TOML data (with sorted keys).
"""
function write_toml(file::String, data::Dict)
    open(file, "w") do io
        TOML.print(io, data, sorted=true)
    end
end

struct RegBranch
    name::String
    version::VersionNumber
    branch::String

    error::Union{Nothing, String}
end

"""
Register the package at `package_repo` / `tree_spect` in `registry`.
"""
function register(
    package_repo::String, pkg::Pkg.Types.Project, tree_hash::String;
    registry::String = DEFAULT_REGISTRY,
    push::Bool = false,
)
    # get info from package registry
    @debug("get info from package registry")
    package_repo = GitTools.normalize_url(package_repo)
    #pkg, tree_hash = get_project(package_repo, tree_spec)
    branch = "register/$(pkg.name)/v$(pkg.version)"

    # get up-to-date clone of registry
    @debug("get up-to-date clone of registry")
    registry = GitTools.normalize_url(registry)
    registry_repo = get_registry(registry)
    registry_path = LibGit2.path(registry_repo)

    # branch registry repo
    @debug("branch registry repo")
    git = `git -C $registry_path`
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
        package_data["name"] == pkg.name ||
            error("changing package names not supported yet")
        package_path = joinpath(registry_path, package_data["path"])
    else
        @debug("Package with UUID: $uuid not found in registry, checking if UUID was changed")
        for (k, v) in registry_data["packages"]
            if v["name"] == pkg.name
                err = "Changing UUIDs is not allowed"
                @debug(err)
                return RegBranch(pkg.name, pkg.version, branch, err)
            end
        end

        @debug("Creating directory for new package $(pkg.name)")
        first_letter = uppercase(pkg.name[1])
        package_path = joinpath(registry_path, "$first_letter", pkg.name)
        mkpath(package_path)
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
    if isfile(versions_file)
        versions_data = TOML.parsefile(versions_file)
    else
        versions_data = Dict()
    end
    versions = sort!([VersionNumber(v) for v in keys(versions_data)])

    try
        Base.check_new_version(versions, pkg.version)
    catch ex
        if isa(ex, ErrorException)
            return RegBranch(pkg.name, pkg.version, branch, ex.msg)
        else
            rethrow(ex)
        end
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
    err = nothing
    for (k, v) in pkg.deps
        u = string(v)
        if haskey(registry_data["packages"], u)
            name_in_reg = registry_data["packages"][u]["name"]
            if name_in_reg != k
                err = "Error in `[deps]`: UUID $u refers to package '$name_in_reg' in registry but deps file has '$k'"
                break
            end
        elseif haskey(BUILTIN_PKGS, k)
            if BUILTIN_PKGS[k] != u
                err = "Error in `[deps]`: UUID $u for package $k should be $(BUILTIN_PKGS[k])"
                break
            end
        else
            err = "Error in `[deps]`: Package '$k' with UUID: $u not found in registry or stdlib"
            break
        end
    end

    err !== nothing && return RegBranch(pkg.name, pkg.version, branch, err)

    deps_data[pkg.version] = pkg.deps
    Pkg.Compress.save(deps_file, deps_data)

    # update package data: compat file
    @debug("check compat section")
    err = nothing
    for (p, v) in pkg.compat
        try
            ver = VersionNumber(v)
            if p == "julia" && ver < v"0.7"
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

    err !== nothing && return RegBranch(pkg.name, pkg.version, branch, err)

    @debug("update package data: compat file")
    compat_file = joinpath(package_path, "Compat.toml")
    if isfile(compat_file)
        compat_data = Pkg.Compress.load(compat_file)
    else
        compat_data = Dict()
    end
    compat_data[pkg.version] = pkg.compat
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
    run(`$git commit -qm $message`)

    # push -f branch to remote
    @debug("push -f branch to remote")
    push && run(`$git push -q -f -u origin $branch`)

    return RegBranch(pkg.name, pkg.version, branch, nothing)
end
