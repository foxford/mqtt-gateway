## -----------------------------------------------------------------------------
## Build
## -----------------------------------------------------------------------------
FROM erlang:21-slim AS build-stage

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
FROM cr.yandex/crp1of6bddata8ain3q5/vernemq:1.11.0-buster.1

COPY --from=build-stage "/build/_rel/mqttgw" "/app/mqttgw/"
COPY "docker/vernemq.conf" "/vernemq/etc/vernemq.conf"

RUN useradd -m vernemq && chown -R vernemq:vernemq /vernemq/data /vernemq/etc /vernemq/log

USER vernemq
