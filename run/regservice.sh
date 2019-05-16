#!/usr/bin/env sh

julia -e 'using Registrator; Registrator.RegService.main()' config.regservice.toml > regservice.log 2>&1
