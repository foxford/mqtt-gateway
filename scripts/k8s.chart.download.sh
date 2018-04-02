#!/bin/bash -e
if [[ ! ${APP} ]]; then >&2 echo "APP is not specified"; exit 1; fi
if [[ ! ${CLUSTER_NAME} ]]; then >&2 echo "CLUSTER_NAME is not specified"; exit 1; fi
if [[ ! ${NAMESPACE} ]]; then >&2 echo "NAMESPACE is not specified"; exit 1; fi
if [[ ! ${GITHUB_API_TOKEN} ]]; then >&2 echo "GITHUB_API_TOKEN is not specified"; exit 1; fi
if [[ ! ${GITHUB_REPO_OWNER} ]]; then >&2 echo "GITHUB_REPO_OWNER is not specified"; exit 1; fi
if [[ ! ${GITHUB_REPO_PATH} ]]; then >&2 echo "GITHUB_REPO_PATH is not specified"; exit 1; fi
if [[ ! ${GITHUB_REPO} ]]; then >&2 echo "GITHUB_REPO is not specified"; exit 1; fi

FILE_TO_DOWNLOAD=${FILE_TO_DOWNLOAD:-"${APP}-configmap.yaml"}
PATH_TO_FILE="${PATH_TO_FILE:-$(pwd)}/${FILE_TO_DOWNLOAD}"

GITHUB_FILE="https://api.github.com/repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO}/contents/${GITHUB_REPO_PATH}/${CLUSTER_NAME}/apps/${APP}/ns/${NAMESPACE}/${FILE_TO_DOWNLOAD}"

curl -fo ${PATH_TO_FILE} \
    --header "Authorization: token ${GITHUB_API_TOKEN}" \
    --header "Accept: application/vnd.github.v3.raw" \
    --remote-name \
    --location ${GITHUB_FILE}
