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
docker run -ti --rm \
    -v "$(pwd)/App.toml.sample:/app/App.toml" \
    -e APP_CONFIG='/app/App.toml' \
    -p 1883:1883 \
    sandbox/mqtt-gateway
## Publishing a message to the broker
MQTT_CLIENT_ID='v1.mqtt3/agents/test.john-doe.example.net' \
    && mosquitto_pub -h $(docker-machine ip) -i "${MQTT_CLIENT_ID}" -t 'foo' -m '{"payload": "bar"}'
```



### Authentication using Json Web Tokens

```bash
## Authnentication should be enabled in 'App.toml'
docker run -ti --rm \
    -v "$(pwd)/App.toml.sample:/app/App.toml" \
    -v "$(pwd)/data/keys/iam.public_key.pem.sample:/app/data/keys/iam.public_key.pem.sample" \
    -e APP_CONFIG='/app/App.toml' \
    -p 1883:1883 \
    sandbox/mqtt-gateway


export ACCOUNT_ID='john-doe.example.net'
export MQTT_CLIENT_ID="v1.mqtt3/agents/${AGENT_ID}"
export ACCESS_TOKEN='eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJ1c3IuZXhhbXBsZS5uZXQiLCJpc3MiOiJpYW0uc3ZjLmV4YW1wbGUubmV0Iiwic3ViIjoiam9obi1kb2UifQ.CjwC4qMT9nGt9oJALiGS6FtpZy3-nhX3L3HyM34Q1sL0P73-7X111A56UlbpQmuu5tGte9-Iu0iMJEYlD5XuGA'

## Subscribing for incoming messages from the APP
mosquitto_sub -h $(docker-machine ip) -i "v1.mqtt3/agents/s.${ACCOUNT_ID}" -P "${ACCESS_TOKEN}" -u 'ignore' -t "agents/s.${ACCOUNT_ID}/api/v1/in/APP"

## Publishing a message to the APP
mosquitto_pub -h $(docker-machine ip) -i "v1.mqtt3/agents/p.${ACCOUNT_ID}" -P "${ACCESS_TOKEN}" -u 'ignore' -t "agents/p.${ACCOUNT_ID}/api/v1/out/APP" -m '{"payload": "bar"}'
```



## Troubleshooting

MQTT Gateway should be built using the same release version of Erlang/OTP as VerneMQ.



## License

The source code is provided under the terms of [the MIT license][license].

[travis]:https://travis-ci.com/netology-group/mqtt-gateway?branch=master
[travis-img]:https://travis-ci.com/netology-group/mqtt-gateway.png?branch=master
[license]:http://www.opensource.org/licenses/MIT
