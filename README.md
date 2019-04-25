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

### Transitioning from REQUIRE to Project.toml

Download [gen_project.jl](https://github.com/JuliaLang/Pkg.jl/blob/master/bin/gen_project.jl), enter in your package directory and run `julia gen_project.jl`, resulting in a `Project.toml` file. You may need to do minor modifications (license, current version, description, etc.) and then remove the REQUIRE file, since it is only used for packages supporting Julia 0.6 and is otherwise irrelevant now.

Check that your package conforms to the required `Project.toml` structure found in the [general package guidelines](https://julialang.github.io/Pkg.jl/v1/creating-packages/).

### Details for triggering JuliaRegistrator (for step 2 above)

1) Using a Pull Request:

Create a pull request on the package repo with your project file changes. Add `` @JuliaRegistrator `register()` `` as the content body of the pull request if you are a collaboarator on the package repository. If you are not a collaborator ask someone who is to comment `` @JuliaRegistrator `register()` `` on the Pull Request. This will make Registrator add a pull request to General by looking at your pull request branch.

2) Using an issue:

Raise an issue in the package you wish to register. Add `` @JuliaRegistrator `register()` `` somewhere in the content of the issue if you are a collaborator to trigger Registrator. If you are not a collaborator ask someone who is to comment `` @JuliaRegistrator `register()` `` on the issue. This will make Registrator add a pull request to General with the appropriate changes. Registrator will look for the project file in the master branch by default. To use a custom branch comment with `` @JuliaRegistrator `register(name-of-your-branch)` ``.

3) Using a commit comment:

On GitHub click on a commit that you wish to register. In the comment section below say `` @JuliaRegistrator `register()` ``. Note that you must be a collaborator in order to do this.


#### If you are a collaborator on the repo

Either:

1. Open an issue and add ` @JuliaRegistrator register() ` as a comment.  You can re-trigger the registrator by commenting ` @JuliaRegistrator register() ` again (in case registrator reports an error or to make changes).
2. Add a comment to a commit and say ` @JuliaRegistrator register() `.

#### If you are not a collaborator

You can request a collaborator trigger registrator in a GitHub issue or a comment on a commit.

### Note on git tags and GitHub releases

The Julia package manager **does not** rely on git tags and GitHub releases. However, Registrator will generate a `git tag` command for you to optionally create a corresponding tag with your package version.

## Approving pull requests on the registry

Currently, a registry maintainer will manually merge the pull request made by Registrator.  We will soon have a CI system to check and auto-merge without human intervention.

#### For private packages and registries

* Same [install](https://github.com/apps/juliaregistrar/installations/new) step as above.
* Add @JuliaRegistrator as a collaborator to your private Registry

#### How to run

See the `image` directory on how to build the docker image.
