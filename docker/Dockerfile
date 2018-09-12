## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM manifesthub/erlang-alpine:19.3.6.5 as build-stage

ENV BUILD_DIR=${BUILD_DIR:-"build"}
ENV container docker

WORKDIR "${BUILD_DIR}"
COPY . "./"

RUN set -xe \
    && apk add --no-cache --virtual .build-deps \
        openssh \
        perl \
        git \
        make \
        curl \
    && make app && make rel \
    && apk del .build-deps

## -----------------------------------------------------------------------------
## App
## -----------------------------------------------------------------------------
#FROM ubuntu:18.04
FROM netologygroup/erlio-vernemq:0.15

MAINTAINER netology-group.ru

ENV BUILD_DIR=${BUILD_DIR:-"/build"}
ENV APP_DIR=${APP_DIR:-"/app"}
ENV APP_NAME='mqttgw'
ENV DEBIAN_FRONTEND noninteractive

## Installing dependencies
RUN set -xe \
    && apt-get update \
    && apt-get -y --no-install-recommends install \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        lsb-release \
        curl \
        make \
        less \
    && rm -rf /var/lib/apt/lists/*

## Configuring VerneMQ
RUN set -xe \
    && VERNEMQ_CONF='/etc/vernemq/vernemq.conf' \
    && perl -pi -e 's/(plugins.vmq_passwd = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_acl = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && printf "\nplugins.${APP_NAME} = on\nplugins.${APP_NAME}.path = ${APP_DIR}\n" >> "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(RUNNER_USER=).*/${1}root\n/s' "/usr/lib/vernemq/lib/env.sh"

COPY --from=build-stage "${BUILD_DIR}/_rel/${APP_NAME}" "${APP_DIR}/"

ENTRYPOINT ["/usr/sbin/start_vernemq"]
