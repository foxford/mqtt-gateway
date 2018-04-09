#!/bin/bash -e
SKAFFOLD_CLI_PATH=${SKAFFOLD_CLI_PATH:-"/tmp"}
GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"
source ${GCLOUD_SDK_PATH}/path.bash.inc

${SKAFFOLD_CLI_PATH}/skaffold run
