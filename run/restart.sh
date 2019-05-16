#!/usr/bin/env bash

if [ $# != 1 ]; then
    echo "USAGE: ./restart.sh <regservice|commentbot|webui>"
fi

if [ ! -f $1.log ]; then
    echo "$1.log not found. Maybe server isn't running"
    rm stop$1
    exit 1
fi

echo "Backing up logs"
DIRNAME=oldlogs/$(date +%d-%h-%yT%T)
mkdir -p $DIRNAME

if [ -f $1.log ]; then
    cp $1.log $DIRNAME
fi

echo "Stopping server"
touch stop$1
# This line works fine on bash but not on sh
timeout 120s grep -q '!stopped!' <(tail -n 1 -f $1.log)

if [ $? -ne 0 ]; then
    echo "ERROR: Timeout waiting for server to stop. Please diagnose the issue and start the server with 'make start'"
else
    nohup ./$1.sh &
    echo "Server started"
fi
