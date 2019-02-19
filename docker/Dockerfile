## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM erlang:21-alpine as build-stage

WORKDIR "/build"
COPY . .

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
FROM ubuntu:18.04

ENV DEBIAN_FRONTEND noninteractive

## Installing dependencies
RUN set -xe \
    && apt-get update \
    && apt-get -y --no-install-recommends install \
        musl-dev \
        apt-transport-https \
        ca-certificates \
        curl \
        less

RUN ln -s /usr/lib/x86_64-linux-musl/libc.so /lib/libc.musl-x86_64.so.1

## Installing VerneMQ
RUN set -xe \
    && VERNEMQ_URI='https://github.com/vernemq/vernemq/releases/download/1.7.0/vernemq-1.7.0.bionic.x86_64.deb' \
    && VERNEMQ_SHA='0934e0286d4f805e18f400f032168b6987a678edb795ee15729c589cd945bef7' \
    && curl -fSL -o vernemq.deb "${VERNEMQ_URI}" \
        && echo "${VERNEMQ_SHA} vernemq.deb" | sha1sum -c - \
        && set +e; dpkg -i vernemq.deb || apt-get -y -f --no-install-recommends install; set -e \
    && rm vernemq.deb

## Configuring VerneMQ
RUN set -xe \
    && VERNEMQ_ENV='/usr/lib/vernemq/lib/env.sh' \
    && perl -pi -e 's/(RUNNER_USER=).*/${1}root\n/s' "${VERNEMQ_ENV}" \
    && VERNEMQ_CONF='/etc/vernemq/vernemq.conf' \
    && perl -pi -e 's/(listener.tcp.default = ).*/${1}0.0.0.0:1883\nlistener.ws.default = 0.0.0.0:8080/g' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_passwd = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && perl -pi -e 's/(plugins.vmq_acl = ).*/${1}off/s' "${VERNEMQ_CONF}" \
    && printf "\nplugins.mqttgw = on\nplugins.mqttgw.path = /app\n" >> "${VERNEMQ_CONF}"

COPY --from=build-stage "/build/_rel/mqttgw" "/app/"
COPY "docker/entrypoint.sh" "/app/entrypoint.sh"

ENTRYPOINT ["/app/entrypoint.sh"]
