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
FROM netologygroup/vernemq:1.11.0

USER root

RUN set -xe \
    && echo "http://dl-cdn.alpinelinux.org/alpine/v3.9/main" >> /etc/apk/repositories \
    && apk add --update \
        libcrypto1.1

RUN mkdir /etc/vernemq
COPY --from=build-stage "/build/_rel/mqttgw" "/app/mqttgw/"
COPY "docker/vernemq.conf" "/vernemq/etc/vernemq.conf"
RUN sed -i.bak -r "s/-name VerneMQ@.+/-name $(cat /vernemq/etc/vernemq.conf | grep nodename | awk -F ' = ' '{print $2}')/" /vernemq/etc/vm.args
