#!/bin/bash

julia run.jl conf.toml > >(tee -a stdout.log) 2> >(tee -a stderr.log >&2)
