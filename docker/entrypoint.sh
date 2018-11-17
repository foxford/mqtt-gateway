#!/bin/bash

set -xe

/usr/sbin/vernemq console -noshell -noinput

PID=$(ps aux | grep '[b]eam.smp' | awk '{print $2}')
tail -f /var/log/vernemq/console.log & wait ${PID}