module GitHubAuth
    using GitHub
    include("conf.jl")

    if USE_JWT
        @info("Authenticating with JWT")
        auth = GitHub.JWTAuth(GITHUB_APP_ID, GITHUB_PRIV_PEM)
    else
        @info("Authenticating with access token")
        auth = GitHub.authenticate(GITHUB_TOKEN)
    end
end
