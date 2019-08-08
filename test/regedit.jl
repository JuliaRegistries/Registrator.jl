using Registrator.RegEdit: RegEdit,
    DEFAULT_REGISTRY_URL,
    parse_registry,
    showsafe,
    registration_branch,
    get_registry
using LibGit2
using Pkg.TOML
using Pkg.Types: Project

using Test

const TEST_GITCONFIG = Dict(
    "user.name" => "RegistratorTests",
    "user.email" => "ci@juliacomputing.com",
)
const TEST_SIGNATURE = LibGit2.Signature(
    TEST_GITCONFIG["user.name"],
    TEST_GITCONFIG["user.email"],
)

@testset "RegEdit" begin

@testset "Utilities" begin
    @testset "showsafe" begin
        @test string(showsafe(3)) == "3"
        @test string(showsafe(nothing)) == "nothing"
    end

    @testset "registration_branch" begin
        example = Project(Dict(
            "name" => "Example", "version" => "1.10.2",
            "uuid" => "698ec630-83b2-4a6d-81d4-a10176273030"
        ))
        @test registration_branch(example) == "registrator/example/698ec630/v1.10.2"
    end
end

@testset "RegistryCache" begin
    @testset "get_registry" begin
        mktempdir(@__DIR__) do temp_cache_dir
            # test when registry is not in the cache and not downloaded
            cache = RegEdit.RegistryCache(temp_cache_dir)
            repo = get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)
            @test LibGit2.path(repo) == RegEdit.path(cache, DEFAULT_REGISTRY_URL)
            @test LibGit2.branch(repo) == "master"
            @test !LibGit2.isdirty(repo)
            @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL

            # test when registry is in the cache but not downloaded
            registry_path = RegEdit.path(cache, DEFAULT_REGISTRY_URL)
            rm(registry_path, recursive=true, force=true)
            @test !ispath(registry_path)
            repo = get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)
            @test LibGit2.path(repo) == RegEdit.path(cache, DEFAULT_REGISTRY_URL)
            @test LibGit2.branch(repo) == "master"
            @test !LibGit2.isdirty(repo)
            @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL

            # test when registry is in the cache, downloaded, but mutated
            orig_hash = LibGit2.GitHash()
            LibGit2.branch!(repo, "newbranch", force=true)
            LibGit2.remove!(repo, "Registry.toml")
            LibGit2.commit(
                repo,
                "Removing Registry.toml in Registrator tests";
                author=TEST_SIGNATURE,
                committer=TEST_SIGNATURE,
            )
            @test LibGit2.GitObject(repo, "HEAD") != LibGit2.GitObject(repo, "master")
            @test ispath(registry_path)
            repo = get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)
            @test LibGit2.path(repo) == RegEdit.path(cache, DEFAULT_REGISTRY_URL)
            @test LibGit2.branch(repo) == "master"
            @test !LibGit2.isdirty(repo)
            @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL
        end
    end
end

@testset "RegistryData" begin
    blank = RegEdit.RegistryData("BlankRegistry", "d4e2f5cd-0f48-4704-9988-f1754e755b45")

    example = Project(Dict(
        "name" => "Example", "uuid" => "7876af07-990d-54b4-ab0e-23690620f79a"
    ))

    @testset "I/O" begin
        registry = """
            name = "General"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://github.com/JuliaRegistries/General.git"

            description = \"\"\"
            Official general Julia package registry where people can
            register any package they want without too much debate about
            naming and without enforced standards on documentation or
            testing. We nevertheless encourage documentation, testing and
            some amount of consideration when choosing package names.
            \"\"\"

            [packages]
            00701ae9-d1dc-5365-b64a-a3a3ebf5695e = { name = "BioAlignments", path = "B/BioAlignments" }
            00718b61-6157-5045-8849-3d4c4093d022 = { name = "Convertible", path = "C/Convertible" }
            0087ddc6-3964-5e57-817f-9937aefb0357 = { name = "MathOptInterfaceMosek", path = "M/MathOptInterfaceMosek" }
            """

        registry_data = parse_registry(IOBuffer(registry))
        @test registry_data isa RegEdit.RegistryData
        written_registry = sprint(TOML.print, registry_data)
        written_registry_data = parse_registry(IOBuffer(written_registry))

        @test written_registry_data == registry_data
        @test written_registry == registry
    end

    @testset "Package Operations" begin
        registry_data = copy(blank)

        @test isempty(registry_data.packages)
        @test push!(registry_data, example) == registry_data
        @test length(registry_data.packages) == 1
        @test haskey(registry_data.packages, string(example.uuid))
        @test registry_data.packages[string(example.uuid)]["name"] == "Example"
        @test registry_data.packages[string(example.uuid)]["path"] == joinpath("E", "Example")
    end
end

@testset "check_version!" begin
    import Registrator.RegEdit: RegBranch, check_version!
    import Pkg.Types: Project

    for ver in ["0.0.2", "0.3.2", "4.3.2"]
        pkg = Project(Dict("name" => "TestTools", "version" => ver))
        regbr = RegBranch(pkg, "test")
        check_version!(regbr, VersionNumber[])
        @test haskey(regbr.metadata, "warning")
        @test length(regbr.metadata["warning"]) != 0
        @test !haskey(regbr.metadata, "error")
    end

    for ver in ["0.0.1", "0.1.0", "1.0.0"]
        pkg = Project(Dict("name" => "TestTools", "version" => ver))
        regbr = RegBranch(pkg, "test")
        check_version!(regbr, VersionNumber[])
        @test !haskey(regbr.metadata, "warning")
        @test !haskey(regbr.metadata, "error")
    end

    versions_list = [v"0.0.5", v"0.1.0", v"0.1.5", v"1.0.0"]
    let    # Less than least existing version
        pkg = Project(Dict("name" => "TestTools", "version" => "0.0.4"))
        regbr = RegBranch(pkg, "test")
        check_version!(regbr, versions_list)
        @test haskey(regbr.metadata, "error")
        @test length(regbr.metadata["error"]) != 0
        @test !haskey(regbr.metadata, "warning")
    end

    let    # Existing version
        pkg = Project(Dict("name" => "TestTools", "version" => "0.0.5"))
        regbr = RegBranch(pkg, "test")
        check_version!(regbr, versions_list)
        @test haskey(regbr.metadata, "error")
        @test length(regbr.metadata["error"]) != 0
        @test !haskey(regbr.metadata, "warning")
    end

    let    # Non-existing version
        pkg = Project(Dict("name" => "TestTools", "version" => "0.0.6"))
        regbr = RegBranch(pkg, "test")
        check_version!(regbr, versions_list)
        @test !haskey(regbr.metadata, "error")
        @test !haskey(regbr.metadata, "warning")
    end

    let    # Skip a version
        pkg = Project(Dict("name" => "TestTools", "version" => "0.0.7"))
        regbr = RegBranch(pkg, "test")
        check_version!(regbr, versions_list)
        @test !haskey(regbr.metadata, "error")
        @test haskey(regbr.metadata, "warning")
        @test length(regbr.metadata["warning"]) != 0
    end
end

end
