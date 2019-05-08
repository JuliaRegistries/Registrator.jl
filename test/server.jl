import Registrator.RegServer: accept_regex, parse_submission_string

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

@testset "parse_submission_string" begin
    @test parse_submission_string("register()") == ("register", [], Dict{Symbol,String}())
    @test parse_submission_string("register(qux)") == ("register", ["qux"], Dict{Symbol,String}())
    @test parse_submission_string("register(qux, baz)") == ("register", ["qux", "baz"], Dict{Symbol,String}())

    @test parse_submission_string("approved()") == ("approved", [], Dict{Symbol,String}())

    @test parse_submission_string("register(target=qux)") == ("register", String[], Dict(:target=>"qux"))
    @test parse_submission_string("register(target=qux, branch=baz)") == ("register", String[], Dict(:branch=>"baz",:target=>"qux"))
    @test parse_submission_string("register(qux, baz, target=foo, branch=bar)") == ("register", ["qux", "baz"], Dict(:branch=>"bar",:target=>"foo"))

    @test parse_submission_string("register(branch=\"release-1.0\")") == ("register", String[], Dict(:branch=>"release-1.0"))
end

end
