#!/bin/bash -e
if [[ ! ${DOCKER_IMAGE_NAME} ]]; then >&2 echo "DOCKER_IMAGE_NAME is not specified"; exit 1; fi
if [[ ! ${DOCKER_IMAGE_OWNER} ]]; then >&2 echo "DOCKER_IMAGE_OWNER is not specified"; exit 1; fi
if [[ ! ${DOCKER_PASSWORD} ]]; then >&2 echo "DOCKER_PASSWORD is not specified"; exit 1; fi
if [[ ! ${DOCKER_USERNAME} ]]; then >&2 echo "DOCKER_USERNAME is not specified"; exit 1; fi

DOCKER_IMAGE_TAG=${DOCKER_IMAGE_TAG:-'latest'}

docker build -f docker/Dockerfile -t "${DOCKER_IMAGE_OWNER}/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" .
docker login -u ${DOCKER_USERNAME} -p ${DOCKER_PASSWORD}
docker push "${DOCKER_IMAGE_OWNER}/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}"
