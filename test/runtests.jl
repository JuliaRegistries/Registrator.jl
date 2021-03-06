using Test

@testset "Registrator" begin

include("server.jl")

# Travis CI gets rate limited easily unless we have access to an API key.
if get(ENV, "TRAVIS", "") == "true" && !haskey(ENV, "GITHUB_API_TOKEN")
    @info "Skipping web tests on Travis CI (credentials are unavailable)"
else
    include("webui.jl")
end
include("webui/gitutils.jl")

end
