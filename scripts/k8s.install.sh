#!/bin/bash -e
GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"
source ${GCLOUD_SDK_PATH}/path.bash.inc

gcloud components install kubectl --quiet
