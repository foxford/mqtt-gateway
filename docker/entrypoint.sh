#!/bin/bash

set -xe

EXIT_HANDLER() {
    echo "Entering into exit handler..."

    vmq-admin cluster leave node=VerneMQ@127.0.0.1 -k > /dev/null
    vernemq stop
}
trap 'EXIT_HANDLER' EXIT SIGINT SIGTERM

/usr/sbin/vernemq start
tail -f '/var/log/vernemq/console.log' & wait ${!}