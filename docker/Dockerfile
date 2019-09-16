## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM erlang:21-alpine as build-stage

WORKDIR "/build"
COPY . .

RUN set -xe \
    && echo "http://dl-cdn.alpinelinux.org/alpine/v3.9/main" >> /etc/apk/repositories \
    && apk add --update \
        ca-certificates \
        libcrypto1.1 \
        curl \
        perl \
        git \
        make \
    && make app && make rel

## -----------------------------------------------------------------------------
## App
## -----------------------------------------------------------------------------
FROM erlio/docker-vernemq:1.9.2-1-alpine

USER root

RUN set -xe \
    && echo "http://dl-cdn.alpinelinux.org/alpine/v3.9/main" >> /etc/apk/repositories \
    && apk add --update \
        libcrypto1.1

COPY --from=build-stage "/build/_rel/mqttgw" "/app/"
COPY "docker/vernemq.conf" "/etc/vernemq/vernemq.conf"
