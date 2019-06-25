# MQTT Gateway

[![Build Status][travis-img]][travis]

MQTT Gateway is a VerneMQ plugin with token based (OAuth2 Bearer Token) authentication.
Authorization for publish/subscribe operations is based conventions and dynamic rules.



### Overview

#### Authentication

| Name           |   Type |  Default | Description                                                      |
| -------------- | ------ | -------- | ---------------------------------------------------------------- |
| MQTT_CLIENT_ID | String | required | `v1/agents/${AGENT_LABEL}.${ACCOUNT_LABEL}.${AUDIENCE}`    |
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
    -e APP_AUTHN_ENABLED=0 \
    -e APP_AUTHZ_ENABLED=0 \
    -p 1883:1883 \
    sandbox/mqtt-gateway

## Subscribing to messages
mosquitto_sub -h $(docker-machine ip) \
    -i 'v1/agents/test-sub.john-doe.usr.example.net' \
    -t 'foo' | jq '.'

## Publishing a message
mosquitto_pub -h $(docker-machine ip) \
    -i 'v1/agents/test-pub.john-doe.usr.example.net' \
    -t 'foo' \
    -m '{"payload": "bar"}'
```



### Authentication using Json Web Tokens

```bash
## Authnentication should be enabled in 'App.toml'
docker run -ti --rm \
    -v "$(pwd)/App.toml.sample:/app/App.toml" \
    -v "$(pwd)/data/keys/iam.public_key.pem.sample:/app/data/keys/iam.public_key.pem.sample" \
    -v "$(pwd)/data/keys/svc.public_key.pem.sample:/app/data/keys/svc.public_key.pem.sample" \
    -e APP_CONFIG='/app/App.toml' \
    -p 1883:1883 \
    sandbox/mqtt-gateway

## Subscribing to messages
ACCESS_TOKEN='eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJzdmMuZXhhbXBsZS5vcmciLCJpc3MiOiJzdmMuZXhhbXBsZS5vcmciLCJzdWIiOiJhcHAifQ.zevlp8zOKY12Wjm8GBpdF5vvbsMRYYEutJelODi_Fj0yRI8pHk2xTkVtM8Cl5KcxOtJtHIshgqsWoUxrTvrdvA' \
APP='app.svc.example.org' \
    && mosquitto_sub -h $(docker-machine ip) \
        -i "v1/service-agents/test.${APP}" \
        -P "${ACCESS_TOKEN}" \
        -u 'ignore' \
        -t "agents/+/api/v1/out/${APP}" | jq '.'

## Publishing a message
ACCESS_TOKEN='eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJ1c3IuZXhhbXBsZS5uZXQiLCJpc3MiOiJpYW0uc3ZjLmV4YW1wbGUubmV0Iiwic3ViIjoiam9obi1kb2UifQ.CjwC4qMT9nGt9oJALiGS6FtpZy3-nhX3L3HyM34Q1sL0P73-7X111A56UlbpQmuu5tGte9-Iu0iMJEYlD5XuGA' \
USER='john-doe.usr.example.net' \
APP='app.svc.example.org' \
    && mosquitto_pub -h $(docker-machine ip) \
        -i "v1/agents/test.${USER}" \
        -P "${ACCESS_TOKEN}" \
        -u 'ignore' \
        -t "agents/test.${USER}/api/v1/out/${APP}" \
        -m '{"payload": "bar"}'
```



### Dynamic subcriptions to app's events

```bash
## Authorization should be enabled in 'App.toml'
docker run -ti --rm \
    -v "$(pwd)/App.toml.sample:/app/App.toml" \
    -e APP_CONFIG='/app/App.toml' \
    -e APP_AUTHN_ENABLED=0 \
    -p 1883:1883 \
    sandbox/mqtt-gateway

## Subscribing to the topic of user's incoming messages
OBSERVER='devops.svc.example.org' \
USER='john.usr.example.net' \
APP='app.svc.example.org' \
    && mosquitto_sub -h $(docker-machine ip) \
        -i "v1/observer-agents/test-1.${OBSERVER}" \
        -t "agents/test.${USER}/api/v1/in/${APP}" | jq '.'

## Creating a dynamic subscription
APP='app.svc.example.org' \
USER='john.usr.example.net' \
BROKER='mqtt-gateway.svc.example.org' \
    && mosquitto_pub -h $(docker-machine ip) \
        -i "v1/service-agents/test.${APP}" \
        -t "agents/test.${APP}/api/v1/out/${BROKER}" \
        -m '{"payload": "{\"object\": [\"rooms\", \"ROOM_ID\", \"events\"], \"subject\": \"v1/agents/test.'${USER}'\"}", "properties": {"type": "request", "method": "subscription.create", "response_topic": "agents/test.'${USER}'/api/v1/in/'${APP}'", "correlation_data": "foobar"}}'

## Publishing an event
APP='app.svc.example.org' \
    && mosquitto_pub -h $(docker-machine ip) \
        -i "v1/service-agents/test.${APP}" \
        -t "apps/${APP}/api/v1/rooms/ROOM_ID/events" \
        -m '{"payload": "{}", "properties": {"label": "room.create"}}'
```

```erlang
%% We can verify receiving the event on newly created subscription using MQTT client
{ok, C} = emqx_client:start_link([{host, {192,168,99,100}}, {port, 1883}, {client_id, <<"v1/agents/test.john.usr.example.net">>}]),
emqx_client:connect(C).

flush().
Shell got {publish,#{client_pid => <0.277.0>,dup => false,
                     packet_id => undefined,
                     payload =>
                         <<"{\"payload\":\"{}\",\"properties\":{\"account_label\":\"app\",\"agent_label\":\"test\",\"audience\":\"svc.example.org\",\"label\":\"room.create\",\"type\":\"event\"}}">>,
                     properties => undefined,qos => 0,retain => false,
                     topic =>
                         <<"apps/app.svc.example.org/api/v1/rooms/ROOM_ID/events">>}}
```



## Troubleshooting

MQTT Gateway should be built using the same release version of Erlang/OTP as VerneMQ.



## License

The source code is provided under the terms of [the MIT license][license].

[travis]:https://travis-ci.com/netology-group/mqtt-gateway?branch=master
[travis-img]:https://travis-ci.com/netology-group/mqtt-gateway.png?branch=master
[license]:http://www.opensource.org/licenses/MIT
