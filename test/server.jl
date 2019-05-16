import Registrator.CommentBot: accept_regex, parse_comment

using Test

@testset "Server" begin

@testset "accept_regex" begin
    r = Regex("@JuliaRegistrator $accept_regex")
    @test match(r, "@JuliaRegistrator register()")[1] == "register()"
    @test match(r, "@JuliaRegistrator register()\r\n\r\n")[1] == "register()"
    @test match(r, """@JuliaRegistrator register()
                Patch notes:
                Release v0.1.0
                Fixes bugs
                """)[1] == "register()"
end

@testset "parse_comment" begin
    @test parse_comment("register()") == ("register", [], Dict{Symbol,String}())
    @test parse_comment("register(qux)") == ("register", ["qux"], Dict{Symbol,String}())
    @test parse_comment("register(qux, baz)") == ("register", ["qux", "baz"], Dict{Symbol,String}())

    @test parse_comment("approved()") == ("approved", [], Dict{Symbol,String}())

    @test parse_comment("register(target=qux)") == ("register", String[], Dict(:target=>"qux"))
    @test parse_comment("register(target=qux, branch=baz)") == ("register", String[], Dict(:branch=>"baz",:target=>"qux"))
    @test parse_comment("register(qux, baz, target=foo, branch=bar)") == ("register", ["qux", "baz"], Dict(:branch=>"bar",:target=>"foo"))

    @test parse_comment("register(branch=\"release-1.0\")") == ("register", String[], Dict(:branch=>"release-1.0"))
end

end
