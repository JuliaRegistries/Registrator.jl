module Registrator

using UUIDs, LibGit2

import Base: PkgId
import Pkg: Pkg, TOML, GitTools

DEFAULT_REGISTRY = "https://github.com/JuliaRegistries/General"

const REGISTRIES = Dict{String,UUID}()

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
function get_project(remote_url::String, tree_spec::String)
    # TODO?: use raw file downloads for GitHub/GitLab
    mktempdir(mkpath("packages")) do tmp
        # bare clone the package repo
        repo = LibGit2.clone(remote_url, joinpath(tmp, "repo"), isbare=true)
        tree = try
            LibGit2.GitObject(repo, tree_spec)
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
            error("$remote_url: git object $(repr(tree_spec)) could not be found")
        end
        tree isa LibGit2.GitTree || (tree = LibGit2.peel(LibGit2.GitTree, tree))

        # check out the requested tree
        tree_path = abspath(tmp, "tree")
        GC.@preserve tree_path begin
            opts = LibGit2.CheckoutOptions(
                checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
                target_directory = Base.unsafe_convert(Cstring, tree_path)
            )
            LibGit2.checkout_tree(repo, tree, options=opts)
        end

        # look for a project file in the tree
        project_file = Pkg.Types.projectfile_path(tree_path)
        project_file !== nothing && isfile(project_file) ||
            error("$remote_url: git tree $(repr(tree_spec)) has no project file")

        # parse the project file
        project = Pkg.Types.read_project(project_file)
        project.name === nothing &&
            error("$package_repo $tree_spec: package has no name")
        project.uuid === nothing &&
            error("$package_repo $tree_spec: package has no UUID")
        project.version === nothing &&
            error("$package_repo $tree_spec: package has no version")

        return project, string(LibGit2.GitHash(tree))
    end
end

"""
Write TOML data (with sorted keys).
"""
function write_toml(file::String, data::Dict)
    open(file, "w") do io
        TOML.print(io, data, sorted=true)
    end
end

"""
Register the package at `package_repo` / `tree_spect` in `registry`.
"""
function register(
    package_repo::String, tree_spec::String;
    registry::String = DEFAULT_REGISTRY,
    push::Bool = false,
)
    # get info from package registry
    package_repo = GitTools.normalize_url(package_repo)
    pkg, tree_hash = get_project(package_repo, tree_spec)
    branch = "register/$(pkg.name)/v$(pkg.version)"

    # get up-to-date clone of registry
    registry = GitTools.normalize_url(registry)
    registry_repo = get_registry(registry)
    registry_path = LibGit2.path(registry_repo)

    # branch registry repo
    git = `git -C $registry_path`
    run(`$git checkout -qf master`)
    run(`$git branch -qf $branch`)
    run(`$git checkout -qf $branch`)

    # find package in registry
    registry_file = joinpath(registry_path, "Registry.toml")
    registry_data = TOML.parsefile(registry_file)
    package_data = registry_data["packages"][string(pkg.uuid)]
    package_data["name"] == pkg.name ||
        error("changing package names not supported yet")
    package_path = joinpath(registry_path, package_data["path"])

    # update package data: package file
    package_info = filter(((k,v),)->!(v isa Dict), Pkg.Types.destructure(pkg))
    delete!(package_info, "version")
    package_info["repo"] = package_repo
    package_file = joinpath(package_path, "Package.toml")
    write_toml(package_file, package_info)

    # update package data: versions file
    versions_file = joinpath(package_path, "Versions.toml")
    versions_data = TOML.parsefile(versions_file)
    versions = sort!([VersionNumber(v) for v in keys(versions_data)])
    Base.check_new_version(versions, pkg.version)
    version_info = Dict{String,Any}("git-tree-sha1" => string(tree_hash))
    versions_data[string(pkg.version)] = version_info
    write_toml(versions_file, versions_data)

    # update package data: deps file
    deps_file = joinpath(package_path, "Deps.toml")
    deps_data = Pkg.Compress.load(deps_file)
    deps_data[pkg.version] = pkg.deps
    Pkg.Compress.save(deps_file, deps_data)

    # update package data: compat file
    compat_file = joinpath(package_path, "Compat.toml")
    compat_data = Pkg.Compress.load(compat_file)
    compat_data[pkg.version] = pkg.compat
    Pkg.Compress.save(compat_file, compat_data)

    # commit changes
    message = """
    New version: $(pkg.name) v$(pkg.version)

    UUID: $(pkg.uuid)
    Repo: $(package_repo)
    Tree: $(string(tree_hash))
    """
    run(`$git add -- $package_path`)
    run(`$git commit -qm $message`)

    # push -f branch to remote
    push && run(`$git push -q -f -u origin $branch`)

    return
end

end # module
