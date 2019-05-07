# Registrator Web UI

# Usage (For Package Maintainers)

This section is for people who want to use Registrator to register their packages.

## Before Registering

### Who Can Register a Package?

If the package is owned by an individual, then you must be that individual, or a collaborator on the repository.
If the package is owned by an organization/group, then you must be a member of that organization.

### Validating `Project.toml`

Your package must have a `Project.toml` file at the repository root.
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

## Environment Variables

Registrator configuration is done mostly with environment variables.
There are some that are required, and some that are optional.

### Required

- `GIT{HUB,LAB}_API_TOKEN`: Your user's API key.
- `GIT{HUB,LAB}_CLIENT_ID`: Your OAuth2 application's client ID.
- `GIT{HUB,LAB}_CLIENT_SECRET`: Your OAuth2 application's client secret.
- `SERVER_URL`: The URL at which your server is accessible.
  This could be something like `http://localhost:4000` for testing, or `https://example.com`.
- `REGISTRY_URL`: Your registry repository's web URL, for example `https://github.com/foo/bar`.

### Optional

- `REGISTRY_CLONE_URL`: Your registry's clone URL.
  This defaults to the previous URL.
  You can use this variable to clone the registry via SSH, for example.
- `GIT{HUB,LAB}_API_URL`: Provider API base URL.
  You should only set this variable if your provider is self-hosted (i.e. with a non-default URL).
- `GIT{HUB,LAB}_AUTH_URL`: OAuth2 authentication URL.
  Only set this for self-hosted providers.
- `GIT{HUB,LAB}_TOKEN_URL`: OAuth2 token exchange URL.p
  Only set this for self-hosted providers.
- `GIT{HUB,LAB}_DISABLE_RATE_LIMITS`: Set to `true` to disable rate limit processing.
  Only set this for self-hosted instances that don't use rate limiting.
- `DISABLED_PROVIDERS`: A space-delimited list of providers to disable.
  If you disable a provider, then you don't need any of its prerequisites mentioned above.
  However, users won't be able to register packages from that provider.
  Use `github` to disable GitHub and `gitlab` to disable GitLab.
- `EXTRA_PROVIDERS`: Path to a Julia file that adds extra providers.
  This should only be used for certain cases when your provider is self-hosted (see next section).
- `REGISTRY_PROVIDER`: The registry provider.
  This is optional, and can usually be inferred from the registry URL.
  You should only set this if provider is one you added yourself or has a URL that does not contain `github` or `gitlab`.
  For GitHub, the value should be `github`, and for GitLab, it should be `gitlab`.
  For any other provider, it should be whatever key you used in your extra providers file.
  
## Adding Extra Providers

In almost all cases, you shouldn't need to do this.
The only real use case is when your registry is on a self-hosted GitHub or GitLab instance, and you also want to allow registering of packages from the public instance of that provider.
The only two providers supported are GitHub and GitLab.
If you do want to do this, then you should set the `EXTRA_PROVIDERS` variable mentioned above.
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
- `client`: A [GitForge](https://cdg.dev/GitForge.jl/dev) `Forge` with access to your provider.
- `scope`: Use `public_repo` for GitHub and `read_user` for GitLab.
- `include_state`: Leave out for GitHub and set `false` for GitLab.
- `token_type`: Leave out for GitHub and set `OAuth2Token` for GitLab.

The OAuth2 application info and URLs are covered above.
When setting your OAuth2 application's callback URL, make sure that it ends with `?provider=$PROVIDER`, where `$PROVIDER` is `mygithub` for the GitHub example above.

## Running the Server

To run the server, first add Registrator to your Julia environment.
Then, make sure that all environment variables are set correctly.
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
The web server will be hosted at `https://myregistrator.com`.

The first thing we'll do is set up a `.env` file with some information we already have.

```sh
#!/usr/bin/env sh

export SERVER_URL="https://myregistrator.com"
export REGISTRY_URL="https://github.com/RegistryOwner/MyRegistry"
```

Next, we create the GitHub and GitLab users and API keys, and save those API keys:

```sh
export GITHUB_API_TOKEN="abc..."
export GITLAB_API_TOKEN="abc..."
```

Next, create OAuth2 applications for both of them.
The callback URLs will be `https://myregistrator.com/callback?provider=github` and `https://myregistrator.com/callback?provider=gitlab`.
Add the client IDs and secrets to our file:

```sh
export GITHUB_CLIENT_ID="abc..."
export GITLAB_CLIENT_ID="abc..."
export GITHUB_CLIENT_SECRET="abc..."
export GITLAB_CLIENT_SECRET="abc..."
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

```sh
export REGISTRY_CLONE_URL="git@github.com:RegistryOwner/MyRegistry.git"
```

Now that this is done, we're ready to run the server.

Install Registrator, apply the environment variables, and run Julia with the server on port 4000:

```sh
julia -e '
    using Pkg; 
    Pkg.add("https://github.com/JuliaRegistries/Registrator.jl")''
source .env
julia -e '
    using Registrator;
    Registrator.WebUI.main(; port=4000)'
```

<!-- TODO: I have no idea how domains, certificates, etc. work. -->

## Basic Recipe: Private Registry

This guide will be almost identical to the one above, but we'll set up a private, self-hosted registry and only allow packages from that provider.

Let's assume we're running a GitLab instance at `https://git.corp.com`, and our repo is at `Registries/General`.
We want to host our instance at `https://registrator.corp.com`.

First, let's again start off with a `.env` file.

```sh
#!/usr/bin/env sh

export DISABLED_PROVIDERS="github"
export REGISTRY_PROVIDER="gitlab"
export GITLAB_API_URL="https://git.corp.com/api/v4"
export GITLAB_AUTH_URL="https://git.corp.com/oauth/authorize"
export GITLAB_TOKEN_URL="https://git.corp.com/oauth/token"
export REGISTRY_URL="https://git.corp.com/Registries/General"
export SERVER_URL="https://registrator.corp.com"
```

We had to set a few URLs manually, and we also disabled GitHub.
Additionally, we set `REGISTRY_PROVIDER="gitlab"` because the string "gitlab" does not occur in our registry's URL.

Next, we create our user, API key, and OAuth application.
Make sure to enable the `read_user` scope, and to set the callback URL to `https://registrator.corp.com/callback?provider=gitlab`.

Add our credentials to the `.env`:

```sh
export GITLAB_API_TOKEN="abc..."
export GITLAB_CLIENT_ID="abc..."
export GITLAB_CLIENT_SECRET="abc..."
```

We'll do the same Git configuration as before, and set our clone URL appropriately:

```sh
export REGISTR_CLONE_URL="git@git.corp.com:Registries/General"
```

And then we're ready.
With the same commands as before, we can run our server!
