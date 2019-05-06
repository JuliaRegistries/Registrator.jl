using Registrator: Registrator
using Registrator.WebUI: @gf
using GitForge: GitForge, get_user
using GitForge.GitHub: GitHub, GitHubAPI, NoToken, Token
using HTTP: HTTP
using Sockets: Sockets

const UI = Registrator.WebUI

const config = Dict(
    "GITHUB_API_TOKEN" => get(ENV, "GITHUB_API_TOKEN", "abc"),
    "GITHUB_CLIENT_ID" => "abc",
    "GITHUB_CLIENT_SECRET" => "abc",
    "GITLAB_API_TOKEN" => "abc",
    "GITLAB_CLIENT_ID" => "abc",
    "GITLAB_CLIENT_SECRET" => "abc",
    "REGISTRY_URL" => "https://github.com/JuliaRegistries/General",
    "SERVER_URL" => "http://localhost:4000",
    "REGISTRY_CLONE_URL" => nothing,
)

@testset "Web UI" begin
    withenv(config...) do
        @testset "Provider initialization" begin
            UI.init_providers()
            @test length(UI.PROVIDERS) == 2
            @test Set(collect(keys(UI.PROVIDERS))) == Set(["github", "gitlab"])
            empty!(UI.PROVIDERS)

            withenv("DISABLED_PROVIDERS" => "github", "GITLAB_DISABLE_RATE_LIMITS" => "true") do
                UI.init_providers()
                @test collect(keys(UI.PROVIDERS)) == ["gitlab"]
                @test !GitForge.has_rate_limits(UI.PROVIDERS["gitlab"].client, identity)
                empty!(UI.PROVIDERS)
            end

            mktemp() do path, io
                extra_provider = """
                    PROVIDERS["myprovider"] = Provider(;
                        name="MyProvider",
                        client=GitHubAPI(),
                        client_id="abc",
                        client_secret="abc",
                        auth_url="abc",
                        token_url="abc",
                        scope="public_repo",
                    )
                    """
                print(io, extra_provider)
                close(io)

                withenv("EXTRA_PROVIDERS" => path) do
                    UI.init_providers()
                    @test haskey(UI.PROVIDERS, "myprovider")
                    empty!(UI.PROVIDERS)
                end
            end
        end

        # Patch the GitHub API client to avoid needing a real API key.
        t = ENV["GITHUB_API_TOKEN"] == "abc" ? NoToken() : Token(ENV["GITHUB_API_TOKEN"])
        UI.init_providers()
        UI.PROVIDERS["github"] = UI.Provider(;
            name="GitHub",
            client=GitHubAPI(; token=t),
            client_id=ENV["GITHUB_CLIENT_ID"],
            client_secret=ENV["GITHUB_CLIENT_SECRET"],
            auth_url="https://github.com/login/oauth/authorize",
            token_url="https://github.com/login/oauth/access_token",
            scope="public_repo",
        )

        @testset "Registry initialization" begin
            UI.init_registry()
            reg = UI.REGISTRY[]
            @test reg.url == reg.clone == ENV["REGISTRY_URL"]
            @test reg.repo isa GitHub.Repo

            withenv("REGISTRY_CLONE_URL" => "git@github.com:JuliaRegistries/General.git") do
                UI.init_registry()
                reg = UI.REGISTRY[]
                @test reg.url == ENV["REGISTRY_URL"]
                @test reg.clone == ENV["REGISTRY_CLONE_URL"]
            end
        end

        # Start the server.
        # TODO: Stop it when this test set is done.
        task = UI.start_server(Sockets.localhost, 4000)

        @testset "404s" begin
            rs = [UI.ROUTE_INDEX, UI.ROUTE_AUTH, UI.ROUTE_CALLBACK, UI.ROUTE_SELECT, UI.ROUTE_REGISTER]
            for r in rs
                resp = HTTP.get(ENV["SERVER_URL"] * r * "/foo"; status_exception=false)
                @test resp.status == 404
                @test occursin("Page not found", String(resp.body))
            end
        end

        @testset "Route: /" begin
            # The response should contain the registry URL and authentication links.
            resp = HTTP.get(ENV["SERVER_URL"]; status_exception=false)
            @test resp.status == 200
            s = String(resp.body)
            @test occursin(ENV["REGISTRY_URL"], s)
            @test occursin("GitHub", s)
            @test occursin("GitLab", s)

            # When a provider is disabled, its authentication link should not appear.
            delete!(UI.PROVIDERS, "gitlab")
            resp = HTTP.get(ENV["SERVER_URL"]; status_exception=false)
            @test resp.status == 200
            s = String(resp.body)
            @test occursin("GitHub", s)
            @test !occursin("GitLab", s)
        end

        @testset "Route: /select" begin
            resp = HTTP.get(ENV["SERVER_URL"] * UI.ROUTE_SELECT; status_exception=false)
            @test resp.status == 200
            @test occursin("package to register", String(resp.body))
        end

        @testset "Route: /register (validation)" begin
            resp = HTTP.get(ENV["SERVER_URL"] * UI.ROUTE_REGISTER; status_exception=false)
            @test resp.status == 405
            @test occursin("Method not allowed", String(resp.body))

            resp = HTTP.post(ENV["SERVER_URL"] * UI.ROUTE_REGISTER; status_exception=false)
            @test resp.status == 400
            @test occursin("Missing or invalid state cookie", String(resp.body))

            # Pretend we've gone through authentication.
            state = "foo"
            client = UI.PROVIDERS["github"].client
            user = @gf get_user(client, "christopher-dG")
            UI.USERS[state] = UI.User(user, client)

            url = ENV["SERVER_URL"] * UI.ROUTE_REGISTER
            cookies = Dict("state" => state)

            body = "package=&ref=master"
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Package URL was not provided", String(resp.body))

            body = "package=foo&ref=master"
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Package URL is invalid", String(resp.body))

            body = "package=https://github.com/foo/bar&ref="
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Branch was not provided", String(resp.body))

            body = "package=https://github.com/JuliaLang/NotARealRepo&ref=master"
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Repository was not found", String(resp.body))

            body = "package=http://github.com/JuliaLang/julia&ref=master"
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Unauthorized to release this package", String(resp.body))
        end
    end
end
