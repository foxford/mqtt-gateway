#!/bin/bash -e
if [[ ! ${NAMESPACE} ]]; then >&2 echo "NAMESPACE is not specified"; exit 1; fi

GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"
source ${GCLOUD_SDK_PATH}/path.bash.inc

kubectl config set-context $(kubectl config current-context) --namespace=${NAMESPACE}
