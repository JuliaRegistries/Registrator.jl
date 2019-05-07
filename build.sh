#!/bin/bash

IMGVER=$(grep "^# Version:" Dockerfile | cut -d":" -f2)

docker build -t registrator:${IMGVER} .
