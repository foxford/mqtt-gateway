#!/bin/bash -e
GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"

if [[ ! ${PATH_TO_CHARTS} ]]; then >&2 echo "path/to/chart[s] should be specified"; exit 1; fi
if [[ ! ${APP} ]]; then >&2 echo "APP is not specified"; exit 1; fi
if [[ ! ${NAMESPACE} ]]; then >&2 echo "NAMESPACE is not specified"; exit 1; fi

K8S_RESOURCE=${K8S_RESOURCE:-"deployment"}

source ${GCLOUD_SDK_PATH}/path.bash.inc
kubectl --namespace=${NAMESPACE} apply -f ${PATH_TO_CHARTS}
kubectl --namespace=${NAMESPACE} patch ${K8S_RESOURCE} ${APP} \
    -p "{\"metadata\":{\"annotations\":{\"date\":\"`date +'%s'`\"}}}"
