#!/usr/bin/env sh
dir=$(dirname $(realpath $0))
julia --project=$dir -e 'using Registrator; Registrator.WebUI.main()' config.web.toml > webui.log 2>&1
