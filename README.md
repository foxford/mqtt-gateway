# MQTT Gateway

[![Build Status][travis-img]][travis]

MQTT Gateway is a VerneMQ plugin with token based (OAuth2 Bearer Token) authentication.
Authorization for publish/subscribe operations is based conventions and dynamic rules.



### Overview

#### Authentication

| Name           |   Type |  Default | Description                                                      |
| -------------- | ------ | -------- | ---------------------------------------------------------------- |
| MQTT_CLIENT_ID | String | required | `${AGENT_LABEL}.${ACCOUNT_LABEL}.${AUDIENCE}`                    |
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
    -e APP_STAT_ENABLED=0 \
    -e APP_ACCOUNT_ID=mqtt-gateway.svc.example.org \
    -e APP_AGENT_LABEL=alpha \
    -p 1883:1883 \
    sandbox/mqtt-gateway

## Subscribing to messages
mosquitto_sub -h $(docker-machine ip) \
    -i 'test-sub.john-doe.usr.example.net' \
    -u 'v2::default' \
    -t 'foo' | jq '.'

## Publishing a message
mosquitto_pub -V 5 -h $(docker-machine ip) \
    -i 'test-pub.john-doe.usr.example.net' \
    -t 'foo' \
    -D connect user-property 'connection_version' 'v2' \
    -D connect user-property 'connection_mode' 'default' \
    -D publish user-property 'label' 'ping' \
    -D publish user-property 'local_timestamp' "$(date +%s000)" \
    -m '{}'
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
        -i "test.${APP}" \
        -P "${ACCESS_TOKEN}" \
        -u 'v2::service' \
        -t "agents/+/api/v1/out/${APP}" | jq '.'

## Publishing a message
ACCESS_TOKEN='eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJ1c3IuZXhhbXBsZS5uZXQiLCJpc3MiOiJpYW0uc3ZjLmV4YW1wbGUubmV0Iiwic3ViIjoiam9obi1kb2UifQ.CjwC4qMT9nGt9oJALiGS6FtpZy3-nhX3L3HyM34Q1sL0P73-7X111A56UlbpQmuu5tGte9-Iu0iMJEYlD5XuGA' \
USER='john-doe.usr.example.net' \
APP='app.svc.example.org' \
    && mosquitto_pub -V 5 -h $(docker-machine ip) \
        -i "test.${USER}" \
        -P "${ACCESS_TOKEN}" \
        -u 'ignore' \
        -t "agents/test.${USER}/api/v1/out/${APP}" \
        -D connect user-property 'connection_version' 'v2' \
        -D connect user-property 'connection_mode' 'default' \
        -D publish user-property 'label' 'ping' \
        -D publish user-property 'local_timestamp' "$(date +%s000)" \
        -m '{}'
```



### Agent's enter & leave notifications

```bash
## Running a container with VerneMQ and the plugin
docker run -ti --rm \
    -v "$(pwd)/App.toml.sample:/app/App.toml" \
    -e APP_CONFIG='/app/App.toml' \
    -e APP_AUTHN_ENABLED=0 \
    -e APP_AUTHZ_ENABLED=0 \
    -p 1883:1883 \
    sandbox/mqtt-gateway

## Subscribing to messages
OBSERVER='devops.svc.example.org' \
BROKER='mqtt-gateway.svc.example.org' \
    && mosquitto_sub -h $(docker-machine ip) \
        -i "test-1.${OBSERVER}" \
        -t "apps/${BROKER}/api/v2/audiences/+/events" \
        -P "${ACCESS_TOKEN}" \
        -u 'v2::observer' \
        | jq '.'

## Publishing a message
mosquitto_pub -V 5 -h $(docker-machine ip) \
    -i 'test-pub.john-doe.usr.example.net' \
    -t 'foo' \
    -D connect user-property 'connection_version' 'v2' \
    -D connect user-property 'connection_mode' 'default' \
    -D publish user-property 'label' 'ping' \
    -D publish user-property 'local_timestamp' "$(date +%s000)" \
    -n
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

# NOTE: will only be possible with resolving of the 'issue:1326'.
# https://github.com/vernemq/vernemq/issues/1326
#
## Subscribing to the topic of user's incoming messages
# OBSERVER='devops.svc.example.org' \
# USER='john.usr.example.net' \
# APP='app.svc.example.org' \
#     && mosquitto_sub -V 5 -h $(docker-machine ip) \
#         -i "test-1.${OBSERVER}" \
#         -t "agents/test.${USER}/api/v1/in/${APP}" \
#         -D connect user-property 'connection_version' 'v2' \
#         -D connect user-property 'connection_mode' 'observer' \
#         | jq '.'

## Subscribing to the topic of user's incoming messages
USER='john.usr.example.net' \
APP='app.svc.example.org' \
    && mosquitto_sub -h $(docker-machine ip) \
        -i "test.${USER}" \
        -t "agents/test.${USER}/api/v1/in/${APP}" \
        -u 'v2::default' \
        | jq '.'

## Subscribing to the topic of app's incoming multicast messages
OBSERVER='devops.svc.example.org' \
APP='app.svc.example.org' \
    && mosquitto_sub -h $(docker-machine ip) \
        -i "test-2.${OBSERVER}" \
        -u 'v2::observer' \
        -t "agents/+/api/v1/out/${APP}" | jq '.'

# NOTE: will only be possible with resolving of the 'issue:1326'.
# https://github.com/vernemq/vernemq/issues/1326
#
# ## Creating a dynamic subscription
# APP='app.svc.example.org' \
# USER='john.usr.example.net' \
# BROKER='mqtt-gateway.svc.example.org' \
#     && mosquitto_pub -V 5 -h $(docker-machine ip) \
#         -i "test.${APP}" \
#         -t "agents/test.${APP}/api/v2/out/${BROKER}" \
#         -D connect user-property 'connection_version' 'v2' \
#         -D connect user-property 'connection_mode' 'service' \
#         -D publish user-property 'type' 'request' \
#         -D publish user-property 'method' 'subscription.create' \
#         -D publish response-topic "agents/test.${USER}/api/v1/in/${APP}" \
#         -D publish correlation-data 'foobar' \
#         -m "{\"object\": [\"rooms\", \"ROOM_ID\", \"events\"], \"subject\": \"test.${USER}\"}"

## Creating a dynamic subscription
# Note that the agent must be subscribed to the in-topic: "agents/test.${USER}/api/v1/in/${APP}"
APP='app.svc.example.org' \
USER='john.usr.example.net' \
    && mosquitto_pub -V 5 -h $(docker-machine ip) \
        -i "test.${APP}" \
        -t "agents/test.${USER}/api/v1/in/${APP}" \
        -D connect user-property 'connection_version' 'v2' \
        -D connect user-property 'connection_mode' 'service' \
        -D publish user-property 'type' 'request' \
        -D publish user-property 'method' 'subscription.create' \
        -D publish response-topic "agents/test.${USER}/api/v1/in/${APP}" \
        -D publish correlation-data 'foobar' \
        -m "{\"object\": [\"rooms\", \"ROOM_ID\", \"events\"], \"subject\": \"test.${USER}\"}"

## Publishing an event
APP='app.svc.example.org' \
    && mosquitto_pub -V 5 -h $(docker-machine ip) \
        -i "test.${APP}" \
        -t "apps/${APP}/api/v1/rooms/ROOM_ID/events" \
        -D connect user-property 'connection_version' 'v2' \
        -D connect user-property 'connection_mode' 'service' \
        -D publish user-property 'type' 'event' \
        -D publish user-property 'label' 'room.create' \
        -m '{}'

# NOTE: will only be possible with resolving of the 'issue:1326'.
# https://github.com/vernemq/vernemq/issues/1326
#
# ## Deleting the dynamic subscription
# APP='app.svc.example.org' \
# USER='john.usr.example.net' \
# BROKER='mqtt-gateway.svc.example.org' \
#     && mosquitto_pub -V 5 -h $(docker-machine ip) \
#         -i "test.${APP}" \
#         -t "agents/test.${APP}/api/v2/out/${BROKER}" \
#         -D connect user-property 'connection_version' 'v2' \
#         -D connect user-property 'connection_mode' 'service' \
#         -D publish user-property 'type' 'request' \
#         -D publish user-property 'method' 'subscription.delete' \
#         -D publish response-topic "agents/test.${USER}/api/v1/in/${APP}" \
#         -D publish correlation-data 'foobar' \
#         -m "{\"object\": [\"rooms\", \"ROOM_ID\", \"events\"], \"subject\": \"test.${USER}\"}"

## Deleting the dynamic subscription
APP='app.svc.example.org' \
USER='john.usr.example.net' \
    && mosquitto_pub -V 5 -h $(docker-machine ip) \
        -i "test.${APP}" \
        -t "agents/test.${USER}/api/v1/in/${APP}" \
        -D connect user-property 'connection_version' 'v2' \
        -D connect user-property 'connection_mode' 'service' \
        -D publish user-property 'type' 'request' \
        -D publish user-property 'method' 'subscription.delete' \
        -D publish response-topic "agents/test.${USER}/api/v1/in/${APP}" \
        -D publish correlation-data 'foobar' \
        -m "{\"object\": [\"rooms\", \"ROOM_ID\", \"events\"], \"subject\": \"test.${USER}\"}"
```

```erlang
%% We can verify that the subscription was created from the VerneMQ terminal
mqttgw_dynsub:list(<<"test.john.usr.example.net">>).

%% [{[<<"apps">>,<<"app.svc.example.org">>,<<"api">>,<<"v1">>,
%%    <<"rooms">>,<<"ROOM_ID">>,<<"events">>],
%%   #{app => <<"app.svc.example.org">>,
%%     object => [<<"rooms">>,<<"ROOM_ID">>,<<"events">>],
%%     version => <<"v1">>}}]
```




## Troubleshooting

MQTT Gateway should be built using the same release version of Erlang/OTP as VerneMQ.



## License

The source code is provided under the terms of [the MIT license][license].

[travis]:https://travis-ci.com/netology-group/mqtt-gateway?branch=master
[travis-img]:https://travis-ci.com/netology-group/mqtt-gateway.png?branch=master
[license]:http://www.opensource.org/licenses/MIT
