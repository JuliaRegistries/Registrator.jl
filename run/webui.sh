#!/usr/bin/env sh

julia -e 'using Registrator; Registrator.WebUI.main()' config.web.toml > webui.log 2>&1
