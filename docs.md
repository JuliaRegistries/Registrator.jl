# Registrator Documentation

This document describes how you can host your own instance of Registrator.

## Running the Registrator server

The server is run with `Registrator.RegServer.main()`. This can be run as a standalone server or as a docker container. See the `image` directory for instructions on how to build the docker image.

You must provide the configuration file as the argument:

```
julia -e 'using Registrator; Registrator.RegServer.main()' conf.toml
```

To safely stop the Registrator server, `touch` the file mentioned as `stop_file` in the config. By default it is `/tmp/stopregistrator`:

```
touch /tmp/stopregistrator
```

## Config file

See `image/scripts/sample.toml` for description of entries in the config file.

## GitHub permissions and subscribed events for the app

You will need read-only permission for: Repository contents, Repository Metadata

You will need read permission for: Issues, Commit Statuses

You will need to subscribe to the following events: Issue comment and commit comment

## Private packages and registries

Do not install the public Registrator on your private packages and Registries. Please host your own Registrator for this.

If you do host your own Registrator, you can set it up on your private package:
* Set `disable_private_registrations` to `false` in the configuration.
* Add the GitHub user that you mention in the configuration file as a collaborator to the private Registry and package.
* Install the GitHub app on the repository.

## Allow private organization members to register

* Set `check_private_membership` to `true` in the configuration file
* Add the GitHub user that you mention in the configuration file as a member to the organization(s)

## The approved() call

The approved() call is a comment you make on a Registry PR. This is *disabled* on the public Registrator as it requires write access to the repository. It does the following:

1) If `register()` was called on a Pull request then that Pull request is merged.
2) A tag and release with the appropriate version is created on the package repository.
3) The Pull request on the Registry is merged.
4) If `register()` was called on an issue, that issue is closed.

Note that you need to install the Registrator app on the Registry for approval process to work.
