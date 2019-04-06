# Registrator

!["amelia robot logo"](graphics/logo.png)

Registrator is a GitHub app that automates creation of registration pull requests for your julia packages to the [General](https://github.com/JuliaRegistries/General) registry. Install the app by clicking on the button below:

[![install](https://img.shields.io/badge/-install%20app-blue.svg)](https://github.com/apps/juliaregistrar/installations/new)

#### How to use

First, install the app on your package(s) as mentioned above.

Whether you want to register a new package or update the version of a package that you have already registered earlier the procedure is the same.

Note that you need to be a collaborator on the package repo that you want to register in order to trigger registrator. If you are the owner of the repo then you count as a collaborator.

If you are not a collaborator then you can ask someone who is a collaborator to invite you. If that isn't possible then:

1) You can open an issue on the package repo you wish to register and ask a collaborator to trigger registrator

2) You can comment on a commit on the package repo that you wish to register asking a collaborator to trigger registrator.

If you are a collaborator you can trigger registrator using these two methods:

1) Open an issue on the package repo you wish to register. Add ` @JuliaRegistrator register() ` as a comment on the issue to trigger registrator. If registrator reports an error with your Project.toml, you can fix the error and re-trigger registrator by commenting ` @JuliaRegistrator register() ` again.

2) Click on a commit that you wish to register. In the comment section below say ` @JuliaRegistrator register() `.

Registrator will look for the project file in the master branch by default. To use a custom branch comment with ` @JuliaRegistrator register(branch=name-of-your-branch) `.

#### Approving pull requests on the registry

Currently you will have to wait for a registry maintainer to merge your pull request on the registry. Soon we will have a CI system which will check and auto-merge the registration PR without human intervention.

#### Note on git tags and GitHub releases

The julia package system does not rely on git tags and GitHub releases. It is therefore left out of the registration process. Once the registration process is done you can optionally create the tag and release. Registrator will generate a `git tag` command for you in its reply.
