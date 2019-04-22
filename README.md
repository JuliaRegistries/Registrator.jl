# Registrator

[![Build Status](https://travis-ci.com/JuliaComputing/Registrator.jl.svg?branch=master)](https://travis-ci.com/JuliaComputing/Registrator.jl)
[![CodeCov](https://codecov.io/gh/JuliaComputing/Registrator.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaComputing/Registrator.jl)

!["amelia robot logo"](graphics/logo.png)

Registrator is a GitHub app that automates creation of registration pull requests for your julia packages to the [General](https://github.com/JuliaRegistries/General) registry. Install the app below!

## Install Registrator:

[![install](https://img.shields.io/badge/-install%20app-blue.svg)](https://github.com/apps/juliaregistrar/installations/new)

## How to Use

First, install the app on your package(s) as mentioned above.  The procedure for registering a new package is the same as for releasing a new version.

1. Set the [Project.toml](Project.toml) version field in your repository to your new desired `version`.
2. Comment `@JuliaRegistrator register()` on the commit/branch you want to release (e.g. like [here](https://github.com/JuliaComputing/Registrator.jl/issues/61#issuecomment-483486641) or [here](https://github.com/chakravala/Grassmann.jl/commit/3c3a92610ebc8885619f561fe988b0d985852fce#commitcomment-33233149)).
3. If something is incorrect, adjust, and redo step 2.
4. Finally, either rely on [TagBot](https://github.com/apps/julia-tagbot) to tag and make a github release or alternatively tag the release manually.

Registrator will look for the project file in the master branch by default, and will use the version set in the Project.toml file via, for example, `version = "0.1.0"`. To use a custom branch comment with:

```
@JuliaRegistrator register(branch=name-of-your-branch)
```

More detailed information about the usage of Registrator can be found in the [full readme](full_readme.md)

### If you are a collaborator on the repo

Either:

1. Open an issue and add ` @JuliaRegistrator register() ` as a comment.  You can re-trigger the registrator by commenting ` @JuliaRegistrator register() ` again (in case registrator reports an error or you wish to make changes).
2. Add a comment to a commit and say ` @JuliaRegistrator register() `.

### If you are not a collaborator

You can request a collaborator trigger registrator in a GitHub issue or a comment on a commit.


## Approving pull requests on the registry

Currently, a registry maintainer will manually merge the pull request made by Registrator.  We will soon have a CI system to check and auto-merge without human intervention.

## Note on git tags and GitHub releases

The Julia package manager **does not** rely on git tags and GitHub releases. However, Registrator will generate a `git tag` command for you to optionally create a corresponding tag with your package version.
