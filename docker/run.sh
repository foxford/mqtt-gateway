#!/bin/bash

sigterm_handler() {
    pid=0
    # this will stop verrnemq process
    pid=$(cat /run/vernemq/vernemq.pid)

    if [[ $pid -ne 0 ]] 
        then
        /usr/sbin/vernemq stop
        wait ${pid}
        exit 143 # 128 + 15 -- SIGTERM
    fi
    
    exit 166 # Abnornal: pid was not found
}
trap "sigterm_handler" SIGTERM

/usr/sbin/vernemq start &

while true
do
    tail -f /var/log/vernemq/console.log & wait ${!}
done
