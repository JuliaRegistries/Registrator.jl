FORGES["github"] = Forge(;
    name="GitHub",
    client=GitHubAPI(; token=Token(ENV["GITHUB_API_TOKEN"])),
    client_id=ENV["GITHUB_CLIENT_ID"],
    client_secret=ENV["GITHUB_CLIENT_SECRET"],
    auth_url="https://github.com/login/oauth/authorize",
    token_url="https://github.com/login/oauth/access_token",
    scope="public_repo",
)

FORGES["gitlab"] = Forge(;
    name="GitLab",
    client=GitLabAPI(; token=PersonalAccessToken(ENV["GITLAB_API_TOKEN"])),
    client_id=ENV["GITLAB_CLIENT_ID"],
    client_secret=ENV["GITLAB_CLIENT_SECRET"],
    auth_url="https://gitlab.com/oauth/authorize",
    token_url="https://gitlab.com/oauth/token",
    scope="read_user",
    include_state=false,
    token_type=PersonalAccessToken,
)
