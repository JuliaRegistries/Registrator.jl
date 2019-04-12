import Registrator.RegServer: parse_submission_string

using Test

@testset "Server" begin

@testset "parse_submission_string" begin
    @test parse_submission_string("register()") == ("register", [], Dict{Symbol,String}())
    @test parse_submission_string("register(qux)") == ("register", ["qux"], Dict{Symbol,String}())
    @test parse_submission_string("register(qux, baz)") == ("register", ["qux", "baz"], Dict{Symbol,String}())

    @test parse_submission_string("approved()") == ("approved", [], Dict{Symbol,String}())

    @test parse_submission_string("register(target=qux)") == ("register", String[], Dict(:target=>"qux"))
    @test parse_submission_string("register(target=qux, branch=baz)") == ("register", String[], Dict(:branch=>"baz",:target=>"qux"))
    @test parse_submission_string("register(qux, baz, target=foo, branch=bar)") == ("register", ["qux", "baz"], Dict(:branch=>"bar",:target=>"foo"))
end

end
