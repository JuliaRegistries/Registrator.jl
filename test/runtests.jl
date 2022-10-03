using Distributed
using Mocking
using Test

using Dates: DateTime
using Logging: Logging
using HTTP: HTTP
using Sockets: Sockets

using GitForge: GitForge, get_user
using GitForge: GitForge, GitHub, GitLab, Bitbucket
using GitForge.GitHub: GitHub, GitHubAPI, NoToken, Token

using Registrator: Registrator
using Registrator.CommentBot: make_trigger, parse_comment
using Registrator.WebUI: @gf
using Registrator.WebUI: isauthorized, AuthFailure, AuthSuccess, User

const UI = Registrator.WebUI
const CONFIG = UI.CONFIG

include("util.jl")

function populate_config!()
    merge!(UI.CONFIG, Dict(
        "ip" => "localhost",
        "port" => 4000,
        "registry_url" => "https://github.com/JuliaRegistries/General",
        "server_url" => "http://localhost:4000",
        "github" => Dict{String, Any}(
            # Note: we highly recommend that you run these tests with a `GITHUB_TOKEN`
            # that has read-only access.
            "token" => get(ENV, "GITHUB_TOKEN", ""),
            "client_id" => "",
            "client_secret" => "",
        ),
        "gitlab" => Dict{String, Any}(
            "token" => "",
            "client_id" => "",
            "client_secret" => "",
        ),
        "bitbucket" => Dict{String, Any}(
            "token" => get(ENV, "BITBUCKET_API_TOKEN", ""),
            "workspace" => "wrburdick",
            "client_id" => "",
            "client_secret" => "",
        ),
    ))
end

function restoreconfig!()
    empty!(UI.CONFIG)
    populate_config!()
end

function mock_provider!()
    # Patch the GitHub API client to avoid needing a real API key.
    t = isempty(CONFIG["github"]["token"]) ? NoToken() : Token(CONFIG["github"]["token"])
    UI.init_providers()
    UI.PROVIDERS["github"] = UI.Provider(;
        name="GitHub",
        client=GitHubAPI(; token=t),
        client_id=CONFIG["github"]["client_id"],
        client_secret=CONFIG["github"]["client_secret"],
        auth_url="https://github.com/login/oauth/authorize",
        token_url="https://github.com/login/oauth/access_token",
        scope="public_repo",
    )
end

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
