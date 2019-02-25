# Registrator

<img src="https://juliaregistrator.github.io/julia_id.jpg" alt="logo" style="width:200px;"/>

Click [here](https://github.com/apps/registratortest/installations/new) to install.

Registrator is a GitHub app that automates creation of registration pull requests for your julia packages to the [General](https://github.com/JuliaRegistries/General) registry.

#### How to use

1) Using a Pull Request:

Create a pull request on the package repo with your project file changes. Add `register()` as the content body of the pull request if you are a collaboarator on the package repository. If you are not a collaborator ask someone who is to comment `register()` on the Pull Request. This will make Registrator add a pull request to General by looking at your pull request branch.

2) Using an issue:

Raise an issue in the package you wish to register. Add `register()` somewhere in the content of the issue if you are a collaborator to trigger Registrator. If you are not a collaborator ask someone who is to comment `register()` on the issue. This will make Registrator add a pull request to General with the appropriate changes. Registrator will look for the project file in the master branch by default. To use a custom branch comment with `register(name-of-your-branch)`.

3) Using a commit comment:

On GitHub click on a commit that you wish to register. In the comment section below say `register()`. Note that you must be a collaborator in order to do this.

#### Permissions and subscribed events for the app

You will need read-only permission for: Repository contents, Issues, Pull Requests, Repository Metadata

You will need to subscribe to the following events: Issue comment and commit comment

#### How to run

See the `image` directory on how to build the docker image.
