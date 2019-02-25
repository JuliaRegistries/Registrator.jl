# Permissions and subscribed events for the app

You will need read-only permission for: Repository contents, Issues, Pull Requests, Repository Metadata

You will need to subscribe to the following events: Issue comment and commit comment

# How to run

You can use the following script to run the main function of registrator. The `flush` calls are for printing the logs when using `nohup`. Copy the `conf.jl.tpl` file and make the necessary edits.


```
ENV["REGISTRATOR_CONF"] = "conf.jl"

using Logging
using Distributed
using Registrator

logger = SimpleLogger(stdout, Logging.Debug)
global_logger(logger)

@async while true
    sleep(5)
    flush(stdout)
    flush(stderr)
end

Registrator.RegServer.main()
```
