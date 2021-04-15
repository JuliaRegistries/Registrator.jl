using Dates: DateTime
using Registrator.WebUI: isauthorized, AuthFailure, AuthSuccess, User, CONFIG, authorize_user_from_file, get_auth_file_content
using GitForge: GitForge, GitHub, GitLab
using HTTP: stacktrace
using Base64

using Mocking

Mocking.activate()

function patch_gitforge(body::Function; is_collaborator=false, is_member=false, get_file_contents="")
    patches = [
        @patch GitForge.is_collaborator(args...) =
            GitForge.Result{Bool}(is_collaborator, nothing, nothing, stacktrace())
        @patch GitForge.is_member(args...) =
            GitForge.Result{Bool}(is_member, nothing, nothing, stacktrace())
        @patch GitForge.get_file_contents(args...) =
            GitForge.Result{String}(get_file_contents, nothing, nothing, stacktrace())
    ]
    
    apply(patches) do
        return body()
    end
end

function patch_auth_file_content(body::Function; file_content=nothing)
    patch = @patch get_auth_file_content(args...) =
            file_content === nothing ? nothing : NamedTuple{(:content,)}((base64encode(file_content),))

    apply(patch) do
        return body()
    end
end

@testset "gitutils" begin

@testset "isauthorized" begin
    @test isauthorized("username", "reponame") == AuthFailure("Unkown user type or repo type")

    @testset "GitHub" begin

        user_email = "user123@example.com"
        some_other_email = "some@example.com"
        user = GitHub.User(login="user123")
        user_with_email = GitHub.User(login="user123", email=user_email)
        org = GitHub.User(login="JuliaLang")
        private_repo = GitHub.Repo(name="Example.jl", private=true, owner=user)
        public_repo_of_user = GitHub.Repo(name="Example.jl", private=false, owner=user, organization=nothing)
        public_repo_of_org = GitHub.Repo(name="Example.jl", private=false, owner=org, organization=org)
        u = User(user, GitHub.GitHubAPI())
        ue = User(user_with_email, GitHub.GitHubAPI())

        @testset "private repo" begin
            # Assuming CONFIG["allow_private"] is false
            @test isauthorized(u, private_repo) == AuthFailure("Repo Example.jl is private")
        end

        @testset "public repo of user" begin
            # User is authorized to register a package they own whether they are collaborator or not
            patch_gitforge(is_collaborator=true) do
                @test isauthorized(u, public_repo_of_user) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false) do
                @test isauthorized(u, public_repo_of_user) == AuthSuccess()
            end
        end

        @testset "public repo of org" begin
            # authorized if user is either a collaborator on the repo or member of the org
            patch_gitforge(is_collaborator=true, is_member=true) do
                @test isauthorized(u, public_repo_of_org) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=true, is_member=false) do
                @test isauthorized(u, public_repo_of_org) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=true) do
                @test isauthorized(u, public_repo_of_org) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=false) do
                @test isauthorized(u, public_repo_of_org) == AuthFailure("User user123 is not a member of the org JuliaLang and not a collaborator on repo Example.jl")
            end
        end

        @testset "public repo of org with authfile" begin
            CONFIG["authtype"] = "authfile"
            # Check authfile to authorize user by email
            patch_auth_file_content(file_content=user_email) do
                @test authorize_user_from_file(GitHub.GitHubAPI(), ue, public_repo_of_org, "") == AuthSuccess()
            end
            patch_auth_file_content(file_content=user_email) do
                @test authorize_user_from_file(GitHub.GitHubAPI(), u, public_repo_of_org, "") == AuthFailure(Registrator.WebUI.EMAIL_ID_NOT_PUBLIC)
            end
            patch_auth_file_content(file_content=nothing) do
                @test authorize_user_from_file(GitHub.GitHubAPI(), ue, public_repo_of_org, "") == AuthFailure(Registrator.WebUI.AUTH_FILE_NOT_FOUND_ERROR)
            end
            patch_auth_file_content(file_content=some_other_email) do
                @test authorize_user_from_file(GitHub.GitHubAPI(), ue, public_repo_of_org, "") == AuthFailure(Registrator.WebUI.USER_NOT_IN_AUTH_LIST_ERROR)
            end
            delete!(CONFIG, "authtype")
        end
    end

    @testset "GitLab" begin

        user_email = "user123@example.com"
        some_other_email = "some@example.com"
        user = GitLab.User(name="user123", username="user123", id=111)
        user_with_email = GitLab.User(name="user123", username="user123", id=111, email=user_email)
        org = GitHub.User(login="JuliaLang")
        org = GitLab.User(name="org123", username="org123", id=222)
        private_project = GitLab.Project(name="Example.jl", visibility="private", owner=user)
        public_project_of_user = GitLab.Project(name="Example.jl", visibility="public", owner=user, namespace=GitLab.Namespace(kind="user"), id=333)
        public_project_of_group = GitLab.Project(name="Example.jl", visibility="public", owner=org, namespace=GitLab.Namespace(kind="group", full_path="org123/subgroup/Example.jl"), id=444)
        u = User(user, GitLab.GitLabAPI())
        ue = User(user_with_email, GitLab.GitLabAPI())

        @testset "private project" begin
            # Assuming CONFIG["allow_private"] is false
            @test isauthorized(u, private_project) == AuthFailure("Project Example.jl is private")
        end

        @testset "public project of user" begin
            # User is authorized to register a package they own whether they are collaborator or not
            patch_gitforge(is_collaborator=true) do
                @test isauthorized(u, public_project_of_user) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false) do
                @test isauthorized(u, public_project_of_user) == AuthSuccess()
            end
        end

        @testset "public project of group" begin
            # authorized if user is a collaborator on the project or member of the group/subgroups
            patch_gitforge(is_collaborator=true, is_member=true) do
                @test isauthorized(u, public_project_of_group) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=true) do
                @test isauthorized(u, public_project_of_group) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=true, is_member=false) do
                @test isauthorized(u, public_project_of_group) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=false) do
                @test isauthorized(u, public_project_of_group) == AuthFailure("Project Example.jl belongs to the group org123/subgroup/Example.jl, and user user123 is not a member of that group or its parent group(s)")
            end
        end

        @testset "public repo of org with authfile" begin
            CONFIG["authtype"] = "authfile"
            # Check authfile to authorize user by email
            patch_auth_file_content(file_content=user_email) do
                @test authorize_user_from_file(GitLab.GitLabAPI(), ue, public_project_of_group, "") == AuthSuccess()
            end
            patch_auth_file_content(file_content=user_email) do
                @test authorize_user_from_file(GitLab.GitLabAPI(), u, public_project_of_group, "") == AuthFailure(Registrator.WebUI.EMAIL_ID_NOT_PUBLIC)
            end
            patch_auth_file_content(file_content=nothing) do
                @test authorize_user_from_file(GitLab.GitLabAPI(), ue, public_project_of_group, "") == AuthFailure(Registrator.WebUI.AUTH_FILE_NOT_FOUND_ERROR)
            end
            patch_auth_file_content(file_content=some_other_email) do
                @test authorize_user_from_file(GitLab.GitLabAPI(), ue, public_project_of_group, "") == AuthFailure(Registrator.WebUI.USER_NOT_IN_AUTH_LIST_ERROR)
            end
            delete!(CONFIG, "authtype")
        end
    end
end

end
