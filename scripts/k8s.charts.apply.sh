#!/bin/bash -e
if [[ ! ${PATH_TO_CHARTS} ]]; then >&2 echo "path/to/chart[s] should be specified"; exit 1; fi
if [[ ! ${NAMESPACE} ]]; then >&2 echo "NAMESPACE is not specified"; exit 1; fi

GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"
source ${GCLOUD_SDK_PATH}/path.bash.inc

kubectl --namespace=${NAMESPACE} apply -f ${PATH_TO_CHARTS}
