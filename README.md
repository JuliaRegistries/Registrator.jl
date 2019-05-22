# Registrator

[![Build Status](https://travis-ci.com/JuliaRegistries/Registrator.jl.svg?branch=master)](https://travis-ci.com/JuliaRegistries/Registrator.jl)
[![CodeCov](https://codecov.io/gh/JuliaRegistries/Registrator.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaRegistries/Registrator.jl)

!["amelia robot logo"](graphics/logo.png)

Registrator is a GitHub app that automates creation of registration pull requests for your julia packages to the [General](https://github.com/JuliaRegistries/General) registry. Install the app below!

## Install Registrator:

[![install](https://img.shields.io/badge/-install%20app-blue.svg)](https://github.com/apps/juliateam-registrator/installations/new)

## How to Use

First, install the app on your package(s) as mentioned above.  The procedure for registering a new package is the same as for releasing a new version.

1. Set the [Project.toml](Project.toml) version field in your repository to your new desired `version`.
2. Comment `@JuliaRegistrator register()` on the commit/branch you want to register (e.g. like [here](https://github.com/JuliaRegistries/Registrator.jl/issues/61#issuecomment-483486641) or [here](https://github.com/chakravala/Grassmann.jl/commit/3c3a92610ebc8885619f561fe988b0d985852fce#commitcomment-33233149)).
3. If something is incorrect, adjust, and redo step 2.
4. Finally, either rely on [TagBot](https://github.com/apps/julia-tagbot) to tag and make a github release or alternatively tag the release manually.

Registrator will look for the project file in the master branch by default, and will use the version set in the Project.toml file via, for example, `version = "0.1.0"`. To use a custom branch comment with:

```
@JuliaRegistrator register(branch="name-of-your-branch")
```

### Transitioning from REQUIRE to Project.toml

Download [gen_project.jl](https://github.com/JuliaLang/Pkg.jl/blob/master/bin/gen_project.jl), enter in your package directory and run `julia gen_project.jl`, resulting in a `Project.toml` file. You may need to do minor modifications (license, current version, description, etc.) and then remove the REQUIRE file, since it is only used for packages supporting Julia 0.6 and is otherwise irrelevant now.

Check that your package conforms to the required `Project.toml` structure found in the [general package guidelines](https://julialang.github.io/Pkg.jl/v1/creating-packages/).

### Details for triggering JuliaRegistrator (for step 2 above)

Either:

1. Open an issue and add ` @JuliaRegistrator register() ` as a comment.  You can re-trigger the registrator by commenting ` @JuliaRegistrator register() ` again (in case registrator reports an error or to make changes).
2. Add a comment to a commit and say ` @JuliaRegistrator register() `.

*Note*: Only *collaborators* on the package repository and *public members* on the organization the package is under are allowed to register. If you are not a collaborator, you can request a collaborator trigger registrator in a GitHub issue or a comment on a commit.

If you want to register as a private member you should host your own instance of Registrator, see [docs.md](https://github.com/JuliaRegistries/Registrator.jl/blob/master/docs.md)

### Release notes

If you have enabled TagBot on your repositories, then you may write your release notes in the same place that you trigger Registrator, or allow them to be automatically generated from closed issues and merged pull requests instead.
These can later be edited via the GitHub releases interface.

To write your release notes, add a section labeled "Release notes:" or "Patch notes:" to your Registrator trigger issue/comment, after the `@JuliaRegistrator` trigger. For example,
```
@JuliaRegistrator register()

Release notes:

Check out my new features!
```

Note that if you have not enabled TagBot, no release will be made at all, and so any release notes you write will not be used.

### Note on git tags and GitHub releases

The Julia package manager **does not** rely on git tags and GitHub releases. However, Registrator will generate a `git tag` command for you to optionally create a corresponding tag with your package version, or you can use TagBot as is mentioned above.

## Approving pull requests on the registry

Currently, a registry maintainer will manually merge the pull request made by Registrator.  We will soon have a CI system to check and auto-merge without human intervention.

## Private packages and registries

Private packages will be ignored by the current running instance of Registrator. Please see [docs.md](https://github.com/JuliaRegistries/Registrator.jl/blob/master/docs.md) on how to host your own Registrator for private packages.

For more info on running your own instance of Registrator, see the documentation in [docs.md](https://github.com/JuliaRegistries/Registrator.jl/blob/master/docs.md)
