using Registrator.Blocklist: is_blocked, load_blocklist!, BLOCKED_IDS, LAST_FETCH, BLOCKLIST_LOCK
using Registrator.WebUI: get_repo_owner_id, get_repo_provider_name
using Dates

@testset "Blocklist" begin
    @testset "disabled when no blocklist_repo configured" begin
        config = Dict{String,Any}()
        @test !is_blocked("github", 12345, config)

        config["blocklist_repo"] = ""
        @test !is_blocked("github", 12345, config)
    end

    @testset "is_blocked checks against correct provider" begin
        config = Dict{String,Any}(
            "blocklist_repo" => "JuliaRegistries/RegistratorBlocklist",
            "blocklist_cache_ttl" => 99999,
            "github" => Dict("token" => "fake"),
        )
        lock(BLOCKLIST_LOCK) do
            empty!(BLOCKED_IDS)
            BLOCKED_IDS["github"] = Set(["12345", "67890"])
            BLOCKED_IDS["gitlab"] = Set(["11111"])
            BLOCKED_IDS["bitbucket"] = Set(["{abc-uuid}"])
        end
        LAST_FETCH[] = now(Dates.UTC)

        # GitHub IDs only match github provider
        @test is_blocked("github", 12345, config)
        @test is_blocked("github", "12345", config)
        @test is_blocked("github", 67890, config)
        @test !is_blocked("github", 99999, config)
        @test !is_blocked("gitlab", 12345, config)   # same ID, wrong provider
        @test !is_blocked("bitbucket", 12345, config)

        # GitLab IDs only match gitlab provider
        @test is_blocked("gitlab", 11111, config)
        @test !is_blocked("github", 11111, config)

        # Bitbucket UUIDs only match bitbucket provider
        @test is_blocked("bitbucket", "{abc-uuid}", config)
        @test !is_blocked("github", "{abc-uuid}", config)

        # Case-insensitive provider matching
        @test is_blocked("GitHub", 12345, config)
        @test is_blocked("GITLAB", 11111, config)
    end

    @testset "org/owner IDs use the same mechanism as user IDs" begin
        config = Dict{String,Any}(
            "blocklist_repo" => "JuliaRegistries/RegistratorBlocklist",
            "blocklist_cache_ttl" => 99999,
            "github" => Dict("token" => "fake"),
        )
        # Simulate blocking an org (GitHub org ID 743164 = JuliaLang)
        lock(BLOCKLIST_LOCK) do
            empty!(BLOCKED_IDS)
            BLOCKED_IDS["github"] = Set(["743164"])
        end
        LAST_FETCH[] = now(Dates.UTC)

        # The org ID is checked via the same is_blocked function
        @test is_blocked("github", 743164, config)
        # A user ID that isn't blocked should still pass
        @test !is_blocked("github", 999999, config)
    end

    @testset "get_repo_owner_id helpers" begin
        # Verify that the helpers return the expected types for use with is_blocked.
        # We can't easily construct full repo objects without API calls,
        # but we can verify the fallback returns nothing.
        @test get_repo_owner_id("not a repo") === nothing
        @test get_repo_provider_name("not a repo") === nothing
    end

    @testset "load_blocklist! is no-op without config" begin
        config = Dict{String,Any}()
        lock(BLOCKLIST_LOCK) do
            empty!(BLOCKED_IDS)
        end
        load_blocklist!(config)
        lock(BLOCKLIST_LOCK) do
            @test isempty(BLOCKED_IDS)
        end

        # No token
        config["blocklist_repo"] = "Org/Repo"
        load_blocklist!(config)
        lock(BLOCKLIST_LOCK) do
            @test isempty(BLOCKED_IDS)
        end
    end
end
