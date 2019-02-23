#!/usr/bin/env bash

if [[ ! ${NAMESPACE} ]]; then echo "NAMESPACE isn't specified" 1>&2; exit 1; fi
if [[ ! ${GITHUB_TOKEN} ]]; then echo "GITHUB_TOKEN isn't specified" 1>&2; exit 1; fi

SOURCE=${SOURCE:-'https://api.github.com/repos/netology-group/environment/contents/cluster/k8s'}

function FILE_FROM_GITHUB() {
    local DEST_DIR="${1}"; if [[ ! "${DEST_DIR}" ]]; then echo "${FUNCNAME[0]}:DEST_DIR isn't specified" 1>&2; exit 1; fi
    local URI="${2}"; if [[ ! "${URI}" ]]; then echo "${FUNCNAME[0]}:URI isn't specified" 1>&2; exit 1; fi

    mkdir -p "${DEST_DIR}"
    curl -fsSL \
        -H "authorization: token ${GITHUB_TOKEN}" \
        -H 'accept: application/vnd.github.v3.raw' \
        -o "${DEST_DIR}/$(basename $URI)" \
        "${URI}"
}

set -ex

FILE_FROM_GITHUB "deploy" "${SOURCE}/deploy/ca.crt"
FILE_FROM_GITHUB "deploy" "${SOURCE}/deploy/docs.sh"
FILE_FROM_GITHUB "deploy" "${SOURCE}/deploy/run.sh"
FILE_FROM_GITHUB "deploy/k8s" "${SOURCE}/apps/mqtt-gateway/ns/_/mqtt-gateway.yaml"
FILE_FROM_GITHUB "deploy/k8s" "${SOURCE}/apps/mqtt-gateway/ns/_/mqtt-gateway-headless.yaml"
FILE_FROM_GITHUB "deploy/k8s" "${SOURCE}/apps/mqtt-gateway/ns/${NAMESPACE}/mqtt-gateway-config.yaml"
FILE_FROM_GITHUB "deploy/k8s" "${SOURCE}/apps/mqtt-gateway/ns/${NAMESPACE}/mqtt-gateway-environment.yaml"
FILE_FROM_GITHUB "deploy/k8s" "${SOURCE}/apps/mqtt-gateway/ns/${NAMESPACE}/mqtt-gateway-loadbalancer.yaml"

chmod u+x deploy/{docs.sh,run.sh}
