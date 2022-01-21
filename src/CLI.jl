
using GitForge, GitForge.GitHub, GitForge.GitLab
using Logging
using RegistryTools
using TOML
include("Registrator.jl")

using Registrator.WebUI: get_log_level

function main(config::AbstractString=isempty(ARGS) ? "config.toml" : first(ARGS))
    merge!(Registrator.WebUI.CONFIG, TOML.parsefile(config)["web"])
    if get(Registrator.WebUI.CONFIG, "enable_logging", true)
        global_logger(SimpleLogger(stdout, get_log_level(get(Registrator.WebUI.CONFIG, "log_level", "INFO"))))
    end

    @show Registrator.WebUI.CONFIG

    # Based on Registrator.WebUI.init_providers()
    gitlab = Registrator.WebUI.CONFIG["gitlab"]
    Registrator.WebUI.PROVIDERS["gitlab"] = Registrator.WebUI.Provider(;
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

    Registrator.WebUI.init_registry()
    
    register()
end


function register()
    pkey = "gitlab"

    provider = get(Registrator.WebUI.PROVIDERS, pkey, nothing)
    # client = typeof(provider.client)(;
    #     url=GitForge.base_url(provider.client),
    #     token=provider.token_type(token),
    #     has_rate_limits=GitForge.has_rate_limits(provider.client, identity),
    # )
    client = provider.client # Not sure what I'm doing here. Skipping oauth token dance I guess?
    u = Registrator.WebUI.User(@Registrator.WebUI.gf(get_user(client)), client)
    @show client
    @show u

    # TODO read these from CLI args
    package = "https://gitlab.company.com/Example.jl/"
    ref = "main"
    notes = ""
    subdir = ""
    regdata = Registrator.WebUI.build_registration_data(u, package, ref, notes, subdir)


    # Based on WebUI.jl action()
    regp = RegistryTools.RegisterParams(
        Registrator.WebUI.cloneurl(regdata.repo, regdata.is_ssh), 
        regdata.project, 
        regdata.tree;
        subdir=regdata.subdir,
        registry=Registrator.WebUI.REGISTRY[].clone, 
        registry_deps=Registrator.WebUI.REGISTRY[].deps, 
        push=true,
    )

    # Based on RegService.jl service()
    # TODO read from config
    regp.gitconfig["user.name"] = "Registrar"
    # regp.gitconfig["user.email"] = ""
    branch = RegistryTools.register(regp)

    # Based on WebUI.jl action()
    if branch === nothing || get(branch.metadata, "error", nothing) !== nothing
        if branch === nothing
            msg = "ERROR: Registrator backend service unreachable"
        else
            msg = "Registration failed: " * branch.metadata["error"]
        end
        state = :errored
    else
        description = something(regdata.repo.description, "")

        title, body = pull_request_contents(;
            registration_type=get(branch.metadata, "kind", ""),
            package=regdata.project.name,
            repo=web_url(regdata.repo),
            user=display_user(regdata.user),
            gitref=regdata.ref,
            version=regdata.project.version,
            commit=regdata.commit,
            release_notes=regdata.notes,
            description=description,
        )

        # Make the PR.
        pr = @Registrator.WebUI.gf make_registration_request(Registrator.WebUI.REGISTRY[], branch.branch, title, body)
        if pr === nothing
            msg = "Registration failed: Making pull request failed"
            state = :errored
        else
            url = web_url(pr)
            msg = """Registry PR successfully created, see it <a href="$url" target="_blank">here</a>!"""
            state = :success
        end
    end
    @debug msg
end