using Registrator.RegEdit: RegEdit, parse_registry
using Pkg.TOML
using Pkg.Types: Project

using Test

@testset "RegEdit" begin

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

end
