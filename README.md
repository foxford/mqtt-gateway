# MQTT Gateway

[![Build Status][travis-img]][travis]

MQTT Gateway is a VerneMQ plugin with token based (OAuth2 Bearer Token) authentication.
Authorization for publish/subscribe operations is based conventions and dynamic rules.



### Overview

#### Authentication

| Name           |   Type |  Default | Description                                                      |
| -------------- | ------ | -------- | ---------------------------------------------------------------- |
| MQTT_CLIENT_ID | String | required | `v1.mqtt3/agents/${AGENT_LABEL}.${ACCOUNT_LABEL}.${AUDIENCE}`    |
| MQTT_PASSWORD  | String | required | JSON Web Token. Token is required if auhentification is enabled. |
| MQTT_USERNAME  | String | optional | The value is ignored                                             |



### How To Use

To build and start playing with the application,
execute following shell commands within different terminal tabs:

```bash
## To build container locally
docker build -t sandbox/mqtt-gateway -f docker/Dockerfile .
## Running a container with VerneMQ and the plugin
cp App.toml.sample App.toml 
docker run -ti --rm \
    -v "$(pwd)/App.toml:/app/App.toml" \
    -e APP_CONFIG='/app/App.toml' \
    -p 1883:1883 \
    sandbox/mqtt-gateway
## Publishing a message to the broker
MQTT_CLIENT_ID='v1.mqtt3/agents/test.john-doe.example.net' \
    mosquitto_pub -h $(docker-machine ip) -i "${MQTT_CLIENT_ID}" -t 'foo' -m '{"payload": "bar"}'
```



### Authentication using Json Web Tokens

```bash
## Authnentication should be enabled in 'App.toml'
docker run -ti --rm \
    -v "$(pwd)/App.toml:/app/App.toml" \
    -v "$(pwd)/data/keys/iam.key.binary.sample:/app/data/keys/iam.key.binary.sample" \
    -e APP_CONFIG='/app/App.toml' \
    -p 1883:1883 \
    sandbox/mqtt-gateway
## Publishing a message to the broker
ACCESS_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJleGFtcGxlLm5ldCIsImlzcyI6ImlhbS5zdmMuZXhhbXBsZS5uZXQiLCJzdWIiOiJqb2huLWRvZSJ9.aTUJeUW6weaxycqfafqK3JP9AP6_PGQfC0ANA045V88' \
MQTT_CLIENT_ID='v1.mqtt3/agents/test.john-doe.example.net' \
    mosquitto_pub -h $(docker-machine ip) -i "${MQTT_CLIENT_ID}" -P "${ACCESS_TOKEN}" -u 'ignore' -t 'foo' -m '{"payload": "bar"}'
```



## Troubleshooting

MQTT Gateway should be built using the same release version of Erlang/OTP as VerneMQ.



## License

The source code is provided under the terms of [the MIT license][license].

[travis]:https://travis-ci.com/netology-group/mqtt-gateway?branch=master
[travis-img]:https://travis-ci.com/netology-group/mqtt-gateway.png?branch=master
[license]:http://www.opensource.org/licenses/MIT
