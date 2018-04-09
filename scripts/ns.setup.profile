#!/bin/bash -e
NAMESPACE=$(if [[ ${TRAVIS_TAG} ]]; then echo 'production'; else echo 'staging'; fi)
export NAMESPACE=${TRAVIS_NAMESPACE:-${NAMESPACE}}
echo "Release was launched. NAMESPACE=${NAMESPACE}"
