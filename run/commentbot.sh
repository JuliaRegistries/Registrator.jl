#!/usr/bin/env sh

julia -e 'using Registrator; Registrator.CommentBot.main()' config.commentbot.toml > commentbot.log 2>&1
