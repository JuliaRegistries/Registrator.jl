import Registrator.RegEdit: write_registry
using Pkg.TOML

using Test

@testset "RegEdit" begin

@testset "write_registry" begin
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

    registry_data = TOML.parse(registry)
    written_registry = sprint(write_registry, registry_data)
    written_registry_data = TOML.parse(written_registry)

    @test written_registry_data == registry_data
    @test written_registry == registry
end

end
