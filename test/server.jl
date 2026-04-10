@testset "Trigger comment" begin
    trigger = make_trigger(Dict("trigger" => "@JuliaRegistrator"))
    @test match(trigger, "@JuliaRegistrator hi") !== nothing
    @test match(trigger, "@juliaregistrator hi") !== nothing
    @test match(trigger, "@Zuliaregistrator hi") === nothing
    @test match(trigger, "@zuliaregistrator hi") === nothing
end

@testset "parse_comment" begin
    @test parse_comment("register()") == ("register", Dict{Symbol,String}())
    @test parse_comment("approved()") == ("approved", Dict{Symbol,String}())

    @test parse_comment("register(target=qux)") == ("register", Dict(:target=>"qux"))
    @test parse_comment("register(target=qux, branch=baz)") == ("register", Dict(:branch=>"baz",:target=>"qux"))
    @test parse_comment("register(target=foo, branch=bar)") == ("register", Dict(:branch=>"bar",:target=>"foo"))

    @test parse_comment("register(branch=\"release-1.0\")") == ("register", Dict(:branch=>"release-1.0"))

    @test parse_comment("register") == ("register", Dict{Symbol, String}())
    @test parse_comment("register branch=foo target=bar") == ("register", Dict(:branch => "foo", :target => "bar"))
    @test parse_comment("register branch = foo target = bar") == ("register", Dict(:branch => "foo", :target => "bar"))
    @test parse_comment("register branch=foo, target=bar") == ("register", Dict(:branch => "foo", :target => "bar"))

    @test parse_comment("register(branch=foo)\nfoobar\"") == ("register", Dict(:branch => "foo"))

    @test parse_comment("register branch=foo branch=bar") == (nothing, nothing)
end

@testset "is_pfile_parseable" begin
    ok, err = Registrator.CommentBot.is_pfile_parseable("")
    @test ok == false
    @test err == "Project file is empty"

    ok, err = Registrator.CommentBot.is_pfile_parseable("a = [")
    @test ok == false
    @test occursin("Could not parse (Julia)Project.toml as TOML:", err)

    ok, err = Registrator.CommentBot.is_pfile_parseable("""
    name = "Foo"
    uuid = "54e30f9d-21f3-4213-8955-9a4b7cb3eed7"
    version = "0.1.0"
    """)
    @test ok == true
    @test err === nothing
end
