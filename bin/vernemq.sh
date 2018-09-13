#!/usr/bin/env bash

IP_ADDRESS=$(ip -4 addr show eth0 | grep -oP "(?<=inet).*(?=/)"| sed -e "s/^[[:space:]]*//" | tail -n 1)

# Ensure the Erlang node name is set correctly
if env | grep -q "VERNEMQ_NODENAME"; then
    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${VERNEMQ_NODENAME}/" /etc/vernemq/vm.args
else
    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${IP_ADDRESS}/" /etc/vernemq/vm.args
fi

if env | grep -q "VERNEMQ_DISCOVERY_NODE"; then
    echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${VERNEMQ_DISCOVERY_NODE}')\"" >> /etc/vernemq/vm.args
fi

# If you encounter "SSL certification error (subject name does not match the host name)", you may try to set VERNEMQ_KUBERNETES_INSECURE to "1".
insecure=""
if env | grep -q "VERNEMQ_KUBERNETES_INSECURE"; then
    insecure="--insecure"
fi

if env | grep -q "VERNEMQ_DISCOVERY_KUBERNETES"; then
    # Let's set our nodename correctly
    VERNEMQ_KUBERNETES_SUBDOMAIN=$(curl -X GET $insecure --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc.cluster.local/api/v1/namespaces/$VERNEMQ_KUBERNETES_NAMESPACE/pods?labelSelector=app=$VERNEMQ_KUBERNETES_APP_LABEL -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" | jq '.items[0].spec.subdomain' | sed 's/"//g' | tr '\n' '\0')
    if [ $VERNEMQ_KUBERNETES_SUBDOMAIN == "null" ]; then
        VERNEMQ_KUBERNETES_HOSTNAME=${POD_NAME}.${VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local
    else
        VERNEMQ_KUBERNETES_HOSTNAME=${POD_NAME}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local
    fi

    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${VERNEMQ_KUBERNETES_HOSTNAME}/" /etc/vernemq/vm.args
    # Hack into K8S DNS resolution (temporarily)
    kube_pod_names=$(curl -X GET $insecure --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc.cluster.local/api/v1/namespaces/$VERNEMQ_KUBERNETES_NAMESPACE/pods?labelSelector=app=$VERNEMQ_KUBERNETES_APP_LABEL -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" | jq '.items[].spec.hostname' | sed 's/"//g' | tr '\n' ' ')
    for kube_pod_name in $kube_pod_names;
    do
        if [ $kube_pod_name == "null" ]
            then
                echo "Kubernetes discovery selected, but no pods found. Maybe we're the first?"
                echo "Anyway, we won't attempt to join any cluster."
                break
        fi
        if [ $kube_pod_name != $POD_NAME ]
            then
                echo "Will join an existing Kubernetes cluster with discovery node at ${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local"
                echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local')\"" >> /etc/vernemq/vm.args
                break
        fi
    done

    # Modify configuration file from configmap
    if [ -f /etc/vernemq.conf ]; then
        cp /etc/vernemq.conf /etc/vernemq/vernemq.conf

        first_group='${1}'
        perl -pi -e "s/(listener.vmq.clustering = ).*:/${first_group}${IP_ADDRESS}:/s" /etc/vernemq/vernemq.conf
    fi
else
    VERNEMQ_CONF='/etc/vernemq/vernemq.conf' \
    && perl -pi -e 's/(plugins.vmq_passwd = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_acl = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && printf "\nplugins.mqttgw = on\nplugins.mqttgw.path = /app\n" >> "${VERNEMQ_CONF}"
fi

# Check configuration file
su - vernemq -c "/usr/sbin/vernemq config generate 2>&1 > /dev/null" | tee /tmp/config.out | grep error
if [ $? -ne 1 ]; then
    echo "configuration error, exit"
    echo "$(cat /tmp/config.out)"
    exit $?
fi

pid=0

# SIGUSR1-handler
siguser1_handler() {
    echo "stopped"
}

# SIGTERM-handler
sigterm_handler() {
    if [ $pid -ne 0 ]; then
        # this will stop the VerneMQ process
        vmq-admin cluster leave node=VerneMQ@$IP_ADDRESS -k > /dev/null
        wait "$pid"
    fi
    exit 143; # 128 + 15 -- SIGTERM
}

# Setup OS signal handlers
trap 'siguser1_handler' SIGUSR1
trap 'sigterm_handler' SIGTERM

# Start VerneMQ
/usr/sbin/vernemq console -noshell -noinput $@
pid=$(ps aux | grep '[b]eam.smp' | awk '{print $2}')
wait $pid

