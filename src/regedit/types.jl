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
