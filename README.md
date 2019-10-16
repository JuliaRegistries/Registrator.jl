# Registrator

[![Build Status](https://travis-ci.com/JuliaRegistries/Registrator.jl.svg?branch=master)](https://travis-ci.com/JuliaRegistries/Registrator.jl)
[![CodeCov](https://codecov.io/gh/JuliaRegistries/Registrator.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaRegistries/Registrator.jl)
[![](https://img.shields.io/badge/docs-latest-blue.svg)](https://JuliaRegistries.github.io/Registrator.jl/dev)

!["amelia robot logo"](graphics/logo.png)

Registrator is a GitHub app that automates creation of registration pull requests for your julia packages to the [General](https://github.com/JuliaRegistries/General) registry. Install the app below!

## Install Registrator:

[![install](https://img.shields.io/badge/-install%20app-blue.svg)](https://github.com/apps/juliateam-registrator/installations/new)

## How to Use

There are two ways to use Registrator: a web interface and a GitHub app.

### Via the Web Interface

This workflow supports repositories hosted on either GitHub or GitLab.

Go to https://pkg.julialang.org/registrator/ and follow the instructions.
There are also more detailed instructions [here](https://juliaregistries.github.io/Registrator.jl/stable/webui/#Usage-(For-Package-Maintainers)-1).

### Via the GitHub App

Unsurprisingly, this method only works for packages whose repositories are hosted on GitHub.

First, install the app on your package(s) as mentioned above.  The procedure for registering a new package is the same as for releasing a new version.

1. Set the [`(Julia)Project.toml`](Project.toml) version field in your repository to your new desired `version`.
2. Comment `@JuliaRegistrator register` on the commit/branch you want to register (e.g. like [here](https://github.com/JuliaRegistries/Registrator.jl/issues/61#issuecomment-483486641) or [here](https://github.com/chakravala/Grassmann.jl/commit/3c3a92610ebc8885619f561fe988b0d985852fce#commitcomment-33233149)).
3. If something is incorrect, adjust, and redo step 2.
4. If the automatic tests pass, but a moderator makes suggestions (e.g., manually updating your `(Julia)Project.toml` to include a [compat] section with version requirements for dependancies), then incorporate suggestions as you see fit into a new commit, and redo step 2 _for the new commit_.  You don't need to do anything to close out the old request.
5. Finally, either rely on [TagBot](https://github.com/apps/julia-tagbot) to tag and make a github release or alternatively tag the release manually.

Registrator will look for the project file in the master branch by default, and will use the version set in the `(Julia)Project.toml` file via, for example, `version = "0.1.0"`. To use a custom branch comment with:

```
@JuliaRegistrator register branch=name-of-your-branch
```

The old pseudo-Julia syntax is also still supported:

```
@JuliaRegistrator register(branch="foo")
```

### Transitioning from REQUIRE to Project.toml

Download [gen_project.jl](https://github.com/JuliaLang/Pkg.jl/blob/934f8b71eb436da6d2bdb30ccfc80e5e11891c5b/bin/gen_project.jl), enter in your package directory and run `julia gen_project.jl`, resulting in a `Project.toml` file. You may need to do minor modifications (license, current version, description, etc.) and then remove the REQUIRE file, since it is only used for packages supporting Julia 0.6 and is otherwise irrelevant now.

Check that your package conforms to the required `Project.toml` structure found in the [general package guidelines](https://julialang.github.io/Pkg.jl/v1/creating-packages/).

### Details for triggering JuliaRegistrator (for step 2 above)

Either:

1. Open an issue and add ` @JuliaRegistrator register` as a comment.  You can re-trigger the registrator by commenting ` @JuliaRegistrator register` again (in case registrator reports an error or to make changes).
2. Add a comment to a commit and say ` @JuliaRegistrator register`.

*Note*: Only *collaborators* on the package repository and *public members* on the organization the package is under are allowed to register. If you are not a collaborator, you can request a collaborator trigger registrator in a GitHub issue or a comment on a commit.

If you want to register as a private member you should host your own instance of Registrator, see the [documentation](https://juliaregistries.github.io/Registrator.jl/stable/hosting/).

### Release notes

If you have enabled TagBot on your repositories, then you may write your release notes in the same place that you trigger Registrator, or allow them to be automatically generated from closed issues and merged pull requests instead.
These can later be edited via the GitHub releases interface.

To write your release notes, add a section labeled "Release notes:" or "Patch notes:" to your Registrator trigger issue/comment, after the `@JuliaRegistrator` trigger. For example,
```
@JuliaRegistrator register

Release notes:

Check out my new features!
```

Note that if you have not enabled TagBot, no release will be made at all, and so any release notes you write will not be used.

### Note on git tags and GitHub releases

The Julia package manager **does not** rely on git tags and GitHub releases. However, Registrator will generate a `git tag` command for you to optionally create a corresponding tag with your package version, or you can use TagBot as is mentioned above.

## Approving pull requests on the registry

Currently, a registry maintainer will manually merge the pull request made by Registrator.  We will soon have a CI system to check and auto-merge without human intervention.

## Private packages and registries

Private packages will be ignored by the current running instance of Registrator. 
Please see the [documentation](https://juliaregistries.github.io/Registrator.jl/stable/hosting/) on how to host your own Registrator for private packages.
