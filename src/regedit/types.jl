"""
    RegEdit.RegistryCache(path, registries=Dict())

Represents a local cache of registry repositories rooted at `path`, where each registry is
stored in a subdirectory corresponding to the registry's UUID.

Maintains a dictionary `registries` which maps registry repository URLs to UUIDs.
"""
struct RegistryCache
    path::String
    registries::Dict{String, UUID}
end

RegistryCache(path) = RegistryCache(path, Dict())

const REGISTRY_CACHE = RegistryCache("registries")

path(cache::RegistryCache) = cache.path
path(cache::RegistryCache, reg_uuid::UUID) = joinpath(path(cache), string(reg_uuid))
function path(cache::RegistryCache, registry_url::AbstractString)
    path(cache, cache.registries[registry_url])
end

"""
    RegEdit.get_registry(registry_url)

Return a `GitRepo` object for an up-to-date copy of `registry`.
Update the existing copy if available.
"""
function get_registry(
    registry_url::AbstractString;
    gitconfig::Dict=Dict(),
    cache::RegistryCache=REGISTRY_CACHE,
)
    if haskey(cache.registries, registry_url)
        registry_path = path(cache, registry_url)

        if !ispath(registry_path)
            mkpath(path(cache))
            run(`git clone $registry_url $registry_path --branch=master`)
        else
            # this is really annoying/impossible to do with LibGit2
            git = gitcmd(registry_path, gitconfig)
            run(`$git config remote.origin.url $registry_url`)
            run(`$git checkout -q -f master`)
            # uses config because git versions <2.17.0 did not have the -P option
            run(`$git -c fetch.pruneTags fetch -q origin master`)
            run(`$git reset -q --hard origin/master`)
        end
    else
        registry_temp = mktempdir(mkpath(path(cache)))
        try
            run(`git clone $registry_url $registry_temp`)
            reg = parse_registry(joinpath(registry_temp, "Registry.toml"))
            registry_uuid = cache.registries[registry_url] = reg.uuid
            registry_path = path(cache, registry_uuid)
            rm(registry_path, recursive=true, force=true)
            mv(registry_temp, registry_path)
        finally
            rm(registry_temp, recursive=true, force=true)
        end
    end

    return LibGit2.GitRepo(registry_path)
end

@auto_hash_equals struct RegistryData
    name::String
    uuid::UUID
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    packages::Dict{String, Dict{String, Any}}
    extra::Dict{String, Any}
end

function RegistryData(
    name::AbstractString,
    uuid::Union{UUID, AbstractString};
    repo::Union{AbstractString, Nothing}=nothing,
    description::Union{AbstractString, Nothing}=nothing,
    packages::Dict=Dict(),
    extras::Dict=Dict(),
)
    RegistryData(name, UUID(uuid), repo, description, packages, extras)
end

function Base.copy(reg::RegistryData)
    RegistryData(
        reg.name,
        reg.uuid,
        reg.repo,
        reg.description,
        deepcopy(reg.packages),
        deepcopy(reg.extra),
    )
end

function parse_registry(io::IO)
    data = TOML.parse(io)

    name = pop!(data, "name")
    uuid = pop!(data, "uuid")
    repo = pop!(data, "repo", nothing)
    description = pop!(data, "description", nothing)
    packages = pop!(data, "packages", Dict())

    RegistryData(name, UUID(uuid), repo, description, packages, data)
end

parse_registry(str::AbstractString) = open(parse_registry, str)

function TOML.print(io::IO, reg::RegistryData)
    println(io, "name = ", repr(reg.name))
    println(io, "uuid = ", repr(string(reg.uuid)))

    if reg.repo !== nothing
        println(io, "repo = ", repr(reg.repo))
    end

    if reg.description !== nothing
        # print long-form string if there are multiple lines
        if '\n' in reg.description
            print(io, """\n
                description = \"\"\"
                $(reg.description)\"\"\"
                """
            )
        else
            println(io, "description = ", repr(reg.description))
        end
    end

    for (k, v) in pairs(reg.extra)
        TOML.print(io, Dict(k => v), sorted=true)
    end

    println(io, "\n[packages]")
    for (uuid, data) in sort!(collect(reg.packages), by=first)
        print(io, uuid, " = { ")
        print(io, "name = ", repr(data["name"]))
        print(io, ", path = ", repr(data["path"]))
        println(io, " }")
    end

    nothing
end

function package_relpath(reg::RegistryData, pkg::Pkg.Types.Project)
    joinpath("$(uppercase(pkg.name[1]))", pkg.name)
end

function Base.push!(reg::RegistryData, pkg::Pkg.Types.Project)
    reg.packages[string(pkg.uuid)] = Dict(
        "name" => pkg.name, "path" => package_relpath(reg, pkg)
    )
    reg
end
