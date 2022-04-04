#!/usr/bin/env sh
dir=$(dirname $(realpath $0))
julia=julia
#julia=/home/bill/Apps/julia-1.7.1/bin/julia
$julia --project=$dir -e 'using Registrator; Registrator.WebUI.main()' config.web.toml > webui.log 2>&1
