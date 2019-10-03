# Registrator Comment Bot

Here we'll discuss hosting an instance of Registrator's comment bot on a local system
behind a subnet for use with a registry other than General.

## Configuring the Machine

The relevant configuration settings here live in the `[commentbot]` section of
`run/config.commentbot.toml`:

* `http_port`: Set this to a port configured on the router to allow HTTP traffic that is
  not otherwise in use (e.g. not what is used for SSH access to the machine).
  This will be the port on which the comment bot service will listen for GitHub events.
* `http_ip`: This is the IP address of the host machine on its network.
  Note that this is NOT localhost, nor is it necessarily the machine's external IP.

You can ensure that the host IP and port are configured properly by running the following
on the host, substituting the appropriate values:
```julia
using HTTP
HTTP.listen(http_ip, http_port) do _
    println("I hear you!")
end
```
then entering the URL `http://<http_ip>:<http_port>` in a browser.
If all goes well, the listener running on the server should print.

## A Bot Account

Since access to private repositories is required to work with a private registry, it's
recommended to set up a "bot" account with limited permission within the organization.
Authenticating as a user with elevated permissions may pose a security risk.
Note that this is true regardless of whether the registry is private, since GitHub
personal access tokens do not currently provide sufficiently granular access permissions.

Once such an account is created, create a personal access token for it for authentication.

In `run/config.commentbot.toml` in the `[commentbot.github]` section, set the following:

* `user`: The GitHub username for the account.
* `token`: A personal access token for authenticating as this user.

In the `[commentbot]` section, set `trigger` to `@<user>`.

## The GitHub App

A [GitHub App](https://developer.github.com/apps/) is required to use the comment bot.
In the organization settings, create a new GitHub App.
Note that this App should be owned by the organization and not by the bot user in order
to be installable without making it public.

Fill out the necessary fields in the app registration.
For the webhook URL, use `http://<http_ip>:<http_port>`, where the values in brackets are
what was entered into `run/config.commentbot.toml` when configuring the host machine.
Enter a webhook secret and record the value you entered as `secret` in the `[commentbot.github]`
section of `run/config.commentbot.toml`.

No organization or user permissions are required.
For repository permissions, set at least:

* Contents: Read-only
* Issues: Read-only
* Metadata: Read-only
* Commit statuses: Read-only

Subscribe to commit and issue comments.

For private registries, ensure that the app is only installable on this account.
