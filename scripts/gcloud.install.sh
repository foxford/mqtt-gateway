#!/bin/bash -e
if [[ ! ${TRAVIS_ENC_ID} ]]; then >&2 echo "TRAVIS_ENC_ID is not specified"; exit 1; fi

SERVICE_ACCOUNT_KEYPATH=${SERVICE_ACCOUNT_KEYPATH:-'/tmp/travis-ci-key.json'}
GCLOUD_SDK_PATH="${HOME}/${GCLOUD_SDK_DIR:-"google-cloud-sdk"}"

TRAVIS_KEY=encrypted_${TRAVIS_ENC_ID}_key
TRAVIS_IV=encrypted_${TRAVIS_ENC_ID}_iv

if [ ! -d "${GCLOUD_SDK_PATH}/bin" ]; then rm -rf ${GCLOUD_SDK_PATH}; export CLOUDSDK_CORE_DISABLE_PROMPTS=1; curl https://sdk.cloud.google.com | bash; fi
${GCLOUD_SDK_PATH}/install.sh -q
source ${GCLOUD_SDK_PATH}/path.bash.inc
openssl aes-256-cbc -K ${!TRAVIS_KEY} -iv ${!TRAVIS_IV} -in .travis-key.json.enc -out ${SERVICE_ACCOUNT_KEYPATH} -d
gcloud auth activate-service-account --key-file ${SERVICE_ACCOUNT_KEYPATH}
rm -f ${SERVICE_ACCOUNT_KEYPATH}
