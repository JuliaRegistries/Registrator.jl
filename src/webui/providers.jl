# A supported provider whose hosted repositories can be registered.
Base.@kwdef struct Provider{F <: GitForge.Forge}
    name::String
    client::F
    client_id::String
    client_secret::String
    auth_url::String
    token_url::String
    scope::String
    include_state::Bool = true
    token_type::Type = typeof(client.token)
end

provider(::Type{GitHubAPI}) = PROVIDERS["github"]
provider(::Type{GitLabAPI}) = PROVIDERS["gitlab"]
provider(::Type{BitbucketAPI}) = PROVIDERS["bitbucket"]

function init_providers()
    if haskey(CONFIG, "github")
        github = CONFIG["github"]
        PROVIDERS["github"] = Provider(;
            name="GitHub",
            client=GitHubAPI(;
                url=get(github, "api_url", GitHub.DEFAULT_URL),
                token=Token(github["token"]),
                has_rate_limits=!get(github, "disable_rate_limits", false),
            ),
            client_id=github["client_id"],
            client_secret=github["client_secret"],
            auth_url=get(github, "auth_url", "https://github.com/login/oauth/authorize"),
            token_url=get(github, "token_url", "https://github.com/login/oauth/access_token"),
            scope="public_repo",
        )
    end

    if haskey(CONFIG, "gitlab")
        gitlab = CONFIG["gitlab"]
        PROVIDERS["gitlab"] = Provider(;
            name="GitLab",
            client=GitLabAPI(;
                url=get(gitlab, "api_url", GitLab.DEFAULT_URL),
                token=PersonalAccessToken(gitlab["token"]),
                has_rate_limits=!get(gitlab, "disable_rate_limits", false),
            ),
            client_id=gitlab["client_id"],
            client_secret=gitlab["client_secret"],
            auth_url=get(gitlab, "auth_url", "https://gitlab.com/oauth/authorize"),
            token_url=get(gitlab, "token_url", "https://gitlab.com/oauth/token"),
            scope="read_user api",
            include_state=false,
            token_type=OAuth2Token,
        )
    end

    if haskey(CONFIG, "bitbucket")
        bitbucket = CONFIG["bitbucket"]
        println("@@@@BITBUCKET: $bitbucket")
        PROVIDERS["bitbucket"] = Provider(;
            name="BitBucket",
            client=BitbucketAPI(;
                url=get(bitbucket, "api_url", Bitbucket.DEFAULT_URL),
                token=Bitbucket.Token(base64encode(bitbucket["token"])),
                has_rate_limits=!get(bitbucket, "disable_rate_limits", false),
                (haskey(bitbucket, "workspace") ? (; workspace=bitbucket["workspace"]) : (;))...,
            ),
            client_id=bitbucket["client_id"],
            client_secret=bitbucket["client_secret"],
            auth_url=get(bitbucket, "auth_url", "https://bitbucket.org/oauth2/authorize"),
            token_url=get(bitbucket, "token_url", "https://bitbucket.org/oauth2/access_token"),
            #scope=bitbucket["scope"],
            scope="repository:write",
        )
    end

    haskey(CONFIG, "extra_providers") && include(CONFIG["extra_providers"])
end
