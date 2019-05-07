#!/usr/bin/env sh

julia -e 'using Registrator; Registrator.RegService.main()' config.toml &> regservice.log
