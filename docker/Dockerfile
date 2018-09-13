## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM manifesthub/erlang-alpine:19.3.6.5 as build-stage

WORKDIR "/build"
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
FROM debian:jessie
ENV container docker
ENV VERNEMQ_KUBERNETES_NAMESPACE default
ENV VERNEMQ_KUBERNETES_APP_LABEL vernemq
ENV VERNEMQ_LOG_CONSOLE console
ENV APP_NAME='mqttgw'
ENV DEBIAN_FRONTEND noninteractive
ENV VERNEMQ_VERSION 1.5.0
MAINTAINER netology-group.ru

RUN set -xe \
    && apt-get update && apt-get install -y \
        libssl-dev \
        logrotate \
        sudo \
        curl \
        jq \
        less \
        make \
        ca-certificates \
        lsb-release \
    && rm -rf /var/lib/apt/lists/* \
    && curl -Lo /tmp/vernemq.deb https://bintray.com/artifact/download/erlio/vernemq/deb/jessie/vernemq_$VERNEMQ_VERSION-1_amd64.deb \
    && dpkg -i /tmp/vernemq.deb \
    && rm /tmp/vernemq.deb

ADD files/vm.args /etc/vernemq/vm.args
ADD bin/vernemq.sh /usr/sbin/start_vernemq
ADD bin/rand_cluster_node.escript /var/lib/vernemq/rand_cluster_node.escript

VOLUME ["/var/log/vernemq", "/var/lib/vernemq", "/etc/vernemq"]

## Configuring VerneMQ
RUN set -xe \
    && VERNEMQ_CONF='/etc/vernemq/vernemq.conf' \
    && perl -pi -e 's/(plugins.vmq_passwd = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_acl = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && printf "\nplugins.${APP_NAME} = on\nplugins.${APP_NAME}.path = /app\n" >> "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(RUNNER_USER=).*/${1}root\n/s' "/usr/lib/vernemq/lib/env.sh"

COPY --from=build-stage "/build/_rel/${APP_NAME}" "/app/"

CMD ["/usr/sbin/start_vernemq"]
