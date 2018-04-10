#!/bin/bash -e
SKAFFOLD_CLI_PATH=${SKAFFOLD_CLI_PATH:-"/tmp"}

curl -Lo skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64
chmod +x skaffold
mv skaffold ${SKAFFOLD_CLI_PATH}
