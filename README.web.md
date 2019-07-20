# Registrator Web UI

# Usage (For Package Maintainers)

This section is for people who want to use Registrator to register their packages.

## Before Registering

### Who Can Register a Package?

If the package is owned by an individual, then you must be that individual, or a collaborator on the repository.
If the package is owned by an organization/group, then you must be a member of that organization.

### Validating `(Julia)Project.toml`

Your package must have a `JuliaProject.toml` or `Project.toml` file at the repository root.
It should contain at least three keys:

- `name`: The name of the package, with no trailing `.jl`.
- `uuid`: The package's UUID, which was likely generated automatically for you.
- `version`: The package's version number, which cannot have been previously registered.

## Registering

Once you've prepared your repository, using Registrator is simple.

1. The first thing to do is to identify yourself as someone who can register your package.
   At the homepage of the site, you'll be greeted by links to log in to either GitHub or GitLab.
   If you're registering a GitHub package, then log into GitHub, and likewise for GitLab.

2. Once authenticated, you'll see a text box to input the URL to your package repository.
   Do so, then press "Submit".
   The page might seem unresponsive for a while, but it'll get back to you within 10 seconds or so.

3. If everything worked out, then you should see a link to a new pull request in the registry!
   Sit back and let a registry maintainer complete the process for you.
   Otherwise, you'll see a (hopefully) informative reason for failure.

<!-- TODO: Screenshots. -->

# Setup (For Registry Maintainers)

This section is for people who want to host an instance of Registrator for their own registry.

## Provider Setup

Here, the term `$PROVIDER` indicates the provider of your registry repository.
In most cases, that will be GitHub, or perhaps GitLab.

You will need:

- A `$PROVIDER` repository for the registry: This should be a given.
- A `$PROVIDER` user: This user must have permissions to push to the registry and create pull requests.
- A `$PROVIDER` API key: This should be created in the user's account.

The OAuth providers currently supported are GitHub and GitLab.
You can choose to support one or both (or none, but that wouldn't be very useful).

For each provider that you support, you will need:

- An OAuth2 application: For letting users authenticate.
  When setting the callback URL, use `$SERVER_URL/callback?provider=(github|gitlab)`.
  The value for `$SERVER_URL` is covered below.
  GitLab will ask you what scopes you want at application creation time, you want `read_user`.
- A user and API key: This can be the same as you created above for `$PROVIDER`.

## Git Setup

Git must be installed on the host computer.
Additionally, it must be configured so that it can push to the registry, preferably as the user you just created.
You should make sure that you've set up any credential handling such as SSH keys.

## Configuration

Registrator configuration is done with a config file.
Some of its values are required, and some are optional.
It's important to note that optional values **must** be omitted or commented out when not in use.

### `[web]` Section

#### Required

- `ip`: The address that your server will listen on.
  For example, `localhost` or `0.0.0.0`.
- `port`: The port that your server will listen to.
- `server_url`: The full URL at which your server will be accessible.
  This could be something like `http://localhost:4000` for testing, or `https://example.com`.
- `registry_url`: Your registry repository's web URL, for example `https://github.com/foo/bar`.
- `stop_file`: Create this file to signal WebUI to shutdown.

#### Optional

- `registry_clone_url`: Your registry's clone URL.
  This defaults to `registry_url`, but you can use this value to clone the registry via SSH, for example.
- `extra_providers`: Path to a Julia file that adds extra providers.
  This should only be used for certain cases when your provider is self-hosted (see next section).
- `registry_provider`: The registry provider, which is usually inferred from the registry URL.
  You should only set this if provider is one you added yourself or has a URL that does not contain `github` or `gitlab`.
  For GitHub, the value should be `github`, and for GitLab, it should be `gitlab`.
  For any other provider, it should be whatever key you used in your extra providers file.
- `registry_deps`: A list of URLs representing any registries that your target registry depends on.
- `disable_release_notes`: Set to `true` to disable the release notes text box.
- `route_prefix`: Base route for the server.
  For example, use `/registrator` to serve the UI on `<your-hostname>/registrator/`.
- `log_level`: The log level. Can be "INFO", "DEBUG", "WARN", "ERROR". Default is "INFO".
- `backend_port`: Port number of the backend registration service. Default is 5555.
- `allow_private`: Set this to `true` if you want to register private packages. Default is `false`.

### `[web.git{hub,lab}]` Section

If you want to disable a provider, simply omit its section.
For example, to support GitHub packages but not GitLab packages, only provide a `[web.github]` section.

#### Required

- `token`: Your user's API key.
- `client_id`: Your OAuth2 application's client ID.
- `client_secret`: Your OAuth2 application's client secret.

#### Optional

- `api_url`: Provider API base URL.
  You should only set this variable if your provider is self-hosted (i.e. with a non-default URL).
- `auth_url`: OAuth2 authentication URL.
  Only set this for self-hosted providers.
- `token_url`: OAuth2 token exchange URL.p
  Only set this for self-hosted providers.
- `disable_rate_limits`: Set to `true` to disable rate limit processing.
  Only set this for self-hosted instances that don't use rate limiting.

## Adding Extra Providers

In almost all cases, you shouldn't need to do this.
The only real use case is when your registry is on a self-hosted GitHub or GitLab instance, and you also want to allow registering of packages from the public instance of that provider.
The only two providers supported are GitHub and GitLab.
If you do want to do this, then you should set `web.extra_providers` as mentioned above.
The file should look like this:

```julia
PROVIDERS["mygithub"] = Provider(;
    name="PrivateGitHub",
    client=GitHubAPI(;
        url="https://api.github.mysite.com",
        token=Token("my_github_token"),
    ),
    client_id="my_oauth_app_client_id",
    client_secret="my_oauth_app_client_secret",
    auth_url="https://github.mysite.com/oauth/authorize",
    token_url="https://github.mysite.com/oauth/token",
    scope="public_repo",
)

PROVIDERS["mygitlab"] = Provider(;
    name="PrivateGitLab",
    client=GitLabAPI(;
        url="https://gitlab.mysite.com/api/v4",
        token=PersonalAccessToken("my_gitlab_token"),
    ),
    client_id="my_oauth_app_client_id",
    client_secret="my_oauth_app_client_secret",
    auth_url="https://gitlab.mysite.com/oauth/authorize",
    token_url="https://gitlab.mysite.com/oauth/token",
    scope="read_user",
    include_state=false,
    token_type=OAuth2Token,
)
```

- `name`: The text displayed on the authentication link.
- `client`: A [GitForge](https://cdg.dev/GitForge.jl/stable) `Forge` with access to your provider.
- `scope`: Use `public_repo` for GitHub and `read_user` for GitLab.
- `include_state`: Leave out for GitHub and set `false` for GitLab.
- `token_type`: Leave out for GitHub and set `OAuth2Token` for GitLab.

The OAuth2 application info and URLs are covered above.
When setting your OAuth2 application's callback URL, make sure that it ends with `?provider=$PROVIDER`, where `$PROVIDER` is `mygithub` for the GitHub example above.

## Running the Server

To run the server, first add Registrator to your Julia environment.
Then, make sure that your configuration file is written correctly.
The following code will start the server:

```julia
using Registrator
Registrator.WebUI.main()
```

A directory called `registries` will be created, which contains your registry.
It's not important to keep it intact, as it is synchronized before registering any package.

## Basic Recipe: Public Registry

Here's a general case of hosting a registry on GitHub and allowing package registrations from both GitHub and GitLab.
The registry will be owned by `RegistryOwner` and the name will be `MyRegistry`.
The web server will be hosted at `https://myregistrator.com`, and run on port 4000.

The first thing we'll do is set up a `config.toml` file with some information we already have.

Note that in this and any following examples, the section names (i.e. `[web]`) will always be included for clarity.
However, they should only appear once in the final file.

```toml
[web]
ip = "0.0.0.0"
port = 4000
server_url = "https://myregistrator.com"
registry_url = "https://github.com/RegistryOwner/MyRegistry"
```

Next, we create the GitHub and GitLab users and API keys, and save those API keys:

```toml
[web.github]
token = "abc..."

[web.gitlab]
token = "abc..."
```

Next, create OAuth2 applications for both of them.
The callback URLs will be `https://myregistrator.com/callback?provider=github` and `https://myregistrator.com/callback?provider=gitlab`.
Add the client IDs and secrets to our file:

```toml
[web.github]
client_id = "abc..."
client_secret = "abc..."

[web.gitlab]
client_id = "abc..."
client_secret = "abc..."
```

Now let's configure Git and set up SSH authentication to GitHub.

Configure name and email by running these commands:

```sh
git config --global user.name Registrator
git config --global user.email registrator@myregistrator.com
```

Then, create an SSH key with `ssh-keygen`, and hit enter a few times to generate a key.
Now go to GitHub user settings and add the public key to your new user.

To actually use this key, we'll set the clone URL for our registry in `.env`:

```toml
[web]
registry_clone_url = "git@github.com:RegistryOwner/MyRegistry.git"
```

Our file is finished, and looks like this:

```toml
[web]
ip = "0.0.0.0"
port = 4000
server_url = "https://myregistrator.com"
registry_url = "https://github.com/RegistryOwner/MyRegistry"
registry_clone_url = "git@github.com:RegistryOwner/MyRegistry.git"

[web.github]
token = "abc..."
client_id = "abc..."
client_secret = "abc..."

[web.gitlab]
token = "abc..."
client_id = "abc..."
client_secret = "abc..."
```

Now that this is done, we're ready to run the server.
Since our config file is at the default location (`config.toml`), we don't need to pass any arguments.

```sh
# Instalation: Just do this once.
julia -e '
    using Pkg;
    Pkg.add("https://github.com/JuliaRegistries/Registrator.jl")'

# Run this every time.
julia -e '
    using Registrator;
    Registrator.WebUI.main()'
```

## Basic Recipe: Private Registry

This guide will be almost identical to the one above, but we'll set up a private, self-hosted registry and only allow packages from that provider.

Let's assume we're running a GitLab instance at `https://git.corp.com`, and our repo is at `Registries/General`.
We want to host our instance at `https://registrator.corp.com`.

First, let's again start off with a TOML file, but this time at `myconfig.toml`:

```toml
[web]
registry_provider = "gitlab"

[web.gitlab]
api_url = "https://git.corp.com/api/v4"
auth_url = "https://git.corp.com/oauth/authorize"
token_url = "https://git.corp.com/oauth/token"
registry_url = "https://git.corp.com/Registries/General"
server_url = "https://registrator.corp.com"
```

As you can see, We had to set a few URLs manually.
Additionally, we set `registry_provider = "gitlab"` because the string "gitlab" does not occur in our registry's URL.

Next, we create our user, API key, and OAuth application.
Make sure to enable the `read_user` scope, and to set the callback URL to `https://registrator.corp.com/callback?provider=gitlab`.

Add our credentials to the file:

```toml
[web.gitlab]
token = "abc..."
client_id = "abc..."
client_secret = "abc..."
```

We'll do the same Git configuration as before, and set our clone URL appropriately:

```toml
[web]
registry_clone_url = "git@git.corp.com:Registries/General"
```

And then we're ready.
We can run it in the same way as before, but passing our non-default config path:

```sh
julia -e '
    using Registrator;
    Registrator.WebUI.main("myconfig.toml")'
```
