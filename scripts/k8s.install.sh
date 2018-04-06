#!/bin/bash -e
GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"

if [[ ! ${CLUSTER_NAME} ]]; then >&2 echo "CLUSTER_NAME is not specified"; exit 1; fi
if [[ ! ${PROJECT} ]]; then >&2 echo "PROJECT is not specified"; exit 1; fi
if [[ ! ${ZONE} ]]; then >&2 echo "ZONE is not specified"; exit 1; fi

source ${GCLOUD_SDK_PATH}/path.bash.inc
gcloud components install kubectl --quiet
gcloud container clusters get-credentials ${CLUSTER_NAME} \
    --zone ${ZONE} \
    --project ${PROJECT}
