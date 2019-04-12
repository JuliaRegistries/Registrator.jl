using Registrator: Registrator
using Registrator.WebUI: @gf
using GitForge: get_user
using GitForge.GitHub: GitHub, GitHubAPI
using HTTP: HTTP
using Sockets: Sockets

const UI = Registrator.WebUI

const config = Dict(
    "GITHUB_API_TOKEN" => "abc",
    "GITHUB_CLIENT_ID" => "abc",
    "GITHUB_CLIENT_SECRET" => "abc",
    "GITLAB_API_TOKEN" => "abc",
    "GITLAB_CLIENT_ID" => "abc",
    "GITLAB_CLIENT_SECRET" => "abc",
    "REGISTRY_URL" => "https://github.com/JuliaRegistries/General",
    "IP" => "localhost",
    "PORT" => "4000",
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

            withenv("DISABLED_PROVIDERS" => "github") do
                UI.init_providers()
                @test collect(keys(UI.PROVIDERS)) == ["gitlab"]
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
        UI.init_providers()
        UI.PROVIDERS["github"] = UI.Provider(;
            name="GitHub",
            client=GitHubAPI(),
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
        server = Sockets.listen(Sockets.InetAddr(Sockets.localhost, parse(Int, ENV["PORT"])))
        @async UI.main(; init=false, server=server)

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

            body = "package=https://github.com/foo/bar&ref=master"
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Repository was not found", String(resp.body))

            # This is an actual repository, it hasn't been touched for >5 years.
            body = "package=http://github.com/foo/ii&ref=master"
            resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
            @test resp.status == 400
            @test occursin("Unauthorized to release this package", String(resp.body))
        end

        # Stop the server.
        close(server)
    end
end
