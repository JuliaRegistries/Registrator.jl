using Test, Random, Pkg, Registrator

tmpdir = joinpath(tempdir(), Random.randstring())
mkdir(tmpdir)
println(tmpdir)

try
    cd(tmpdir)

    # Create an empty registry
    Registrator.create_registry("TestRegistry", "not_a_real_repo")
    @test isfile(joinpath(tmpdir, "TestRegistry", "Registry.toml"))

    # Create a package to register
    Pkg.generate("TestPackage")
    pkgpath = joinpath(tmpdir, "TestPackage")
    run(`git -C $pkgpath init`)
    run(`git -C $pkgpath add --all`)
    run(`git -C $pkgpath commit -m 'initial commit'`)
    Pkg.activate("TestPackage")
    using TestPackage

    Registrator.register(TestPackage, "TestRegistry"; repo="not_a_real_repo")
finally
    rm(tmpdir, recursive=true)
end
