using Distributed
using Mocking
using Test

using Dates: DateTime
using Logging: Logging
using HTTP: HTTP
using Sockets: Sockets

using GitForge: GitForge, get_user
using GitForge: GitForge, GitHub, GitLab
using GitForge.GitHub: GitHub, GitHubAPI, NoToken, Token

using Registrator: Registrator
using Registrator.CommentBot: make_trigger, parse_comment
using Registrator.WebUI: @gf
using Registrator.WebUI: isauthorized, AuthFailure, AuthSuccess, User

const UI = Registrator.WebUI

include("util.jl")

@testset "Registrator" begin
    @testset "server" begin
        include("server.jl")
    end

    @testset "webui/gitutils" begin
        include("webui/gitutils.jl")
    end

    @testset "webui" begin
        if !haskey(ENV, "GITHUB_TOKEN")
            msg = string(
                "Note: we highly recommend that you run these tests with a ",
                "`GITHUB_TOKEN` that has read-only access.",
            )
            @warn msg
        end

        include("webui.jl")
    end
end
