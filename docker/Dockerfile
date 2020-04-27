## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM erlang:21-alpine as build-stage

RUN set -xe \
    && echo "http://dl-cdn.alpinelinux.org/alpine/v3.9/main" >> /etc/apk/repositories \
    && apk add --update \
        ca-certificates \
        libcrypto1.1 \
        curl \
        perl \
        git \
        make

WORKDIR "/build"
COPY . .
RUN make app && make rel

## -----------------------------------------------------------------------------
## App
## -----------------------------------------------------------------------------
FROM netologygroup/vernemq:1.10.2

USER root

RUN set -xe \
    && echo "http://dl-cdn.alpinelinux.org/alpine/v3.9/main" >> /etc/apk/repositories \
    && apk add --update \
        libcrypto1.1

RUN mkdir /etc/vernemq
COPY --from=build-stage "/build/_rel/mqttgw" "/app/mqttgw/"
COPY "docker/vernemq.conf" "/app/etc/vernemq.conf"
