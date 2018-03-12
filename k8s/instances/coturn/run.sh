#!/bin/bash

#log location
log='log-file='
log_location='/var/log/turnserver.log'

pid=0

sigterm_handler() {
    pid=$(cat /var/run/turnserver.pid)
    # this will stop coturn process
    if [[ $pid -ne 0 ]] 
    then
        kill -SIGTERM ${pid}
        wait ${pid}
        exit 143 # 128 + 15 -- SIGTERM
    fi
    exit 166 # Abnornal: pid was not found
}


trap "sigterm_handler" SIGTERM

/usr/bin/turnserver -c /etc/turnserver.conf --pidfile /var/run/turnserver.pid  --no-stdout-log &


while true
do
    tail -f /var/log/turn_$(cat /var/run/turnserver.pid)*  & wait ${!}
done

