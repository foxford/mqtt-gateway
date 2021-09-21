## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM erlang:21-slim as build-stage

RUN apt update && apt install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    libssl-dev \
    git \
    curl \
    perl

WORKDIR "/build"
COPY . .
RUN make app && make rel

## -----------------------------------------------------------------------------
## App
## -----------------------------------------------------------------------------
FROM foxford/vernemq:1.11.0-buster.1
USER root

RUN mkdir /etc/vernemq
COPY --from=build-stage "/build/_rel/mqttgw" "/app/mqttgw/"
COPY "docker/vernemq.conf" "/vernemq/etc/vernemq.conf"
RUN sed -i.bak -r "s/-name VerneMQ@.+/-name $(cat /vernemq/etc/vernemq.conf | grep nodename | awk -F ' = ' '{print $2}')/" /vernemq/etc/vm.args
