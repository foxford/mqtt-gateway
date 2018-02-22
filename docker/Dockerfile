## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM manifesthub/erlang-alpine:19.3.6.5 as build-stage

ENV BUILD_DIR=${BUILD_DIR:-"build"}

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
FROM ubuntu:16.04

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
        less

## Installing VerneMQ
RUN set -xe \
    && VERNEMQ_URI='https://bintray.com/artifact/download/erlio/vernemq/deb/xenial/vernemq_1.3.0-1_amd64.deb' \
    && VERNEMQ_SHA='84244d2787b308c7a8307e35f11dcdae9c24722e' \
    && curl -fSL -o vernemq.deb "${VERNEMQ_URI}" \
        && echo "${VERNEMQ_SHA} vernemq.deb" | sha1sum -c - \
        && set +e; dpkg -i vernemq.deb || apt-get -y -f --no-install-recommends install; set -e \
&& rm vernemq.deb

## Configuring VerneMQ
RUN set -xe \
    && VERNEMQ_CONF='/etc/vernemq/vernemq.conf' \
    && perl -pi -e 's/(listener.tcp.default = ).*/${1}0.0.0.0:1883\nlistener.ws.default = 0.0.0.0:8080/g' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_passwd = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_acl = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && printf "\nplugins.${APP_NAME} = on\nplugins.${APP_NAME}.path = ${APP_DIR}\n" >> "${VERNEMQ_CONF}"

COPY --from=build-stage "${BUILD_DIR}/_rel/${APP_NAME}" "${APP_DIR}/"

ENTRYPOINT ["/bin/bash", "-c", "/usr/sbin/vernemq start && tail -f /var/log/vernemq/console.log & wait ${!}"]
