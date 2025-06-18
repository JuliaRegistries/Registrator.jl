Mocking.activate()

function patch_gitforge(body::Function; is_collaborator=false, is_member=false)
    patches = [
        @patch GitForge.is_collaborator(args...) = is_collaborator
        @patch GitForge.is_member(args...) = is_member
    ]

    apply(patches) do
        return body()
    end
end

restoreconfig!()

@testset "gittreesha" begin
    org = GitHub.User(login="JuliaLang")

    public_repo_of_org = GitHub.Repo(name="Example.jl", private=false, owner=org, organization=org, permissions = GitHub.Permissions(admin = true, push = false, pull = true), clone_url="https://github.com/JuliaLang/Example.jl.git")
    example_master_treesha = Base.redirect_stderr(devnull) do
        Registrator.WebUI.gettreesha(public_repo_of_org, "master", "")
    end
    @test length(example_master_treesha) == 40

    ret, err = Base.redirect_stderr(devnull) do
        Registrator.WebUI.gettreesha(public_repo_of_org, "mas ter", "")
    end
    @test ret === nothing
    @test err == "Exception while getting tree SHA"

    ret, err = Base.redirect_stderr(devnull) do
        Registrator.WebUI.gettreesha(public_repo_of_org, "master", "src/../test")
    end
    @test ret === nothing
    @test err == "Exception while getting tree SHA"

    ret, err = Base.redirect_stderr(devnull) do
        Registrator.WebUI.gettreesha(public_repo_of_org, "master", "src test")
    end
    @test ret === nothing
    @test err == "Exception while getting tree SHA"

    unsafe_repo = GitHub.Repo(name="Example.jl", private=false, owner=org, organization=org, permissions = GitHub.Permissions(admin = true, push = false, pull = true), clone_url="https://github.com/JuliaLang/../unsafe/Example.jl.git")
    ret, err = Base.redirect_stderr(devnull) do
        Registrator.WebUI.gettreesha(unsafe_repo, "master", "")
    end
    @test ret === nothing
    @test err == "Exception while getting tree SHA"

    unsafe_repo = GitHub.Repo(name="Example.jl", private=false, owner=org, organization=org, permissions = GitHub.Permissions(admin = true, push = false, pull = true), clone_url="http://google.com/ HTTP/1.1\r\nFoo: bar\r\nbaz:")
    ret, err = Base.redirect_stderr(devnull) do
        Registrator.WebUI.gettreesha(unsafe_repo, "master", "")
    end
    @test ret === nothing
    @test err == "Exception while getting tree SHA"
end

@testset "is_safe_clone_url()" begin
    patterns = ["../", "..\\", "/..", "\\..", "./", ".\\", "/./", "\\.\\"]
    for pattern in patterns
        @test !Registrator.WebUI.is_safe_clone_url(pattern)
    end

    @test Registrator.WebUI.is_safe_clone_url("https://github.com/JuliaLang/Example.jl.git")
    @test Registrator.WebUI.is_safe_clone_url("https://oauth2:abcd@gitlab.com/orga/orgb/thing.jl")
end

@testset "isauthorized" begin
    @test isauthorized("username", "reponame") == AuthFailure("Unkown user type or repo type")
    mock_provider!()

    Registrator.WebUI.withpasswd("https://foo:bar\">&baz@github.com/owner/repo") do newurl,envs
        askpass=envs[1]
        script=split(askpass, '=')[2]
    
        # run script and ask it to print out username
        username = strip(read(Cmd(String["sh", script, "Username"]), String))
        @test username == "foo"
    
        # run script and ask it to print out password
        password = strip(read(Cmd(String["sh", script, "Password"]), String))
        @test password == "bar\">&baz"
    end

    @testset "GitHub" begin
        user = GitHub.User(login="user123")
        org = GitHub.User(login="JuliaLang")
        private_repo = GitHub.Repo(name="Example.jl", private=true, owner=user, permissions = GitHub.Permissions(admin = true, push = false, pull = true))
        public_repo_of_user = GitHub.Repo(name="Example.jl", private=false, owner=user, organization=nothing, permissions = GitHub.Permissions(admin = true, push = false, pull = true))
        public_repo_of_org = GitHub.Repo(name="Example.jl", private=false, owner=org, organization=org, permissions = GitHub.Permissions(admin = true, push = false, pull = true))
        u = User(user, GitHub.GitHubAPI())

        @testset "private repo" begin
            # Assuming CONFIG["allow_private"] is false
            @test isauthorized(u, private_repo, false) == AuthFailure("Repo Example.jl is private")
        end

        @testset "public repo of user" begin
            # authorized if user is a collaborator on the repo
            patch_gitforge(is_collaborator=true) do
                @test isauthorized(u, public_repo_of_user, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false) do
                @test isauthorized(u, public_repo_of_user, false) == AuthFailure("User user123 is not a collaborator on repo Example.jl")
            end
        end

        @testset "public repo of org" begin
            # authorized if user is either a collaborator on the repo or member of the org
            patch_gitforge(is_collaborator=true, is_member=true) do
                @test isauthorized(u, public_repo_of_org, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=true, is_member=false) do
                @test isauthorized(u, public_repo_of_org, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=true) do
                @test isauthorized(u, public_repo_of_org, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=false) do
                result = isauthorized(u, public_repo_of_org, false)
                @test result isa AuthFailure
                @test startswith(strip(result.reason), "User user123 is not a collaborator on repository Example.jl and does not appear to be a member of the JuliaLang organization")
            end
        end
    end

    @testset "GitLab" begin

        user = GitLab.User(name="user123", username="user123", id=111)
        org = GitLab.User(name="org123", username="org123", id=222)
        private_project = GitLab.Project(name="Example.jl", visibility="private", owner=user)
        public_project_of_user = GitLab.Project(name="Example.jl", visibility="public", owner=user, namespace=GitLab.Namespace(kind="user"))
        public_project_of_group = GitLab.Project(name="Example.jl", visibility="public", owner=org, namespace=GitLab.Namespace(kind="group", full_path="org123/subgroup/Example.jl"))
        u = User(user, GitLab.GitLabAPI())

        @testset "private project" begin
            # Assuming CONFIG["allow_private"] is false
            @test isauthorized(u, private_project, false) == AuthFailure("Project Example.jl is private")
        end

        @testset "public project of user" begin
            # authorized if user is a collaborator on the project
            patch_gitforge(is_collaborator=true) do
                @test isauthorized(u, public_project_of_user, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false) do
                @test isauthorized(u, public_project_of_user, false) == AuthFailure("User user123 is not a member of project Example.jl")
            end
        end

        @testset "public project of group" begin
            # authorized if user is a collaborator on the project or member of the group/subgroups
            patch_gitforge(is_collaborator=true, is_member=true) do
                @test isauthorized(u, public_project_of_group, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=true) do
                @test isauthorized(u, public_project_of_group, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=true, is_member=false) do
                @test isauthorized(u, public_project_of_group, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=false) do
                @test isauthorized(u, public_project_of_group, false) == AuthFailure("Project Example.jl belongs to the group org123/subgroup/Example.jl, and user user123 is not a member of that group or its parent group(s)")
            end
        end
    end

    @testset "Bitbucket" begin

        #user = @gf get_user(UI.PROVIDERS["bitbucket"].client, "wrburdick")
        user = Bitbucket.User(; nickname = "wrburdick")
        uworkspace = Bitbucket.Workspace(slug="wrb-julia-test")
        workspace = Bitbucket.Workspace(slug="wrburdick")
        private_repo = Bitbucket.Repo(; slug="Example.jl", is_private=true, owner=user, workspace=uworkspace)
        public_repo_of_user = Bitbucket.Repo(; slug="Example.jl", is_private=false, owner=user, workspace)
        public_repo_of_org = Bitbucket.Repo(; slug="Example.jl", is_private=false, owner=user, workspace)
        u = User(user, Bitbucket.BitbucketAPI())

        @testset "private repo" begin
            # Assuming CONFIG["allow_private"] is false
            @test isauthorized(u, private_repo, false) == AuthFailure("Repo $(private_repo.slug) is private")
        end

        @testset "public repo of user" begin
            # authorized if user is a collaborator on the repo
            patch_gitforge(is_collaborator=true) do
                @test isauthorized(u, public_repo_of_user, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false) do
                @test isauthorized(u, public_repo_of_user, false) == AuthFailure("User $(user.nickname) is not a member of the workspace $(workspace.slug) or a collaborator on repo $(public_repo_of_user.slug)")
            end
        end

        @testset "public repo of org" begin
            # authorized if user is either a collaborator on the repo or member of the org
            patch_gitforge(is_collaborator=true, is_member=true) do
                @test isauthorized(u, public_repo_of_org, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=true, is_member=false) do
                @test isauthorized(u, public_repo_of_org, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=true) do
                @test isauthorized(u, public_repo_of_org, false) == AuthSuccess()
            end
            patch_gitforge(is_collaborator=false, is_member=false) do
                @test isauthorized(u, public_repo_of_org, false) == AuthFailure("User $(user.nickname) is not a member of the workspace $(workspace.slug) or a collaborator on repo $(public_repo_of_org.slug)")
            end
        end
    end
end
