#!/usr/bin/env sh
dir=$(dirname $(realpath $0))
julia --project=$dir -e 'using Registrator; Registrator.RegService.main()' config.regservice.toml > regservice.log 2>&1
