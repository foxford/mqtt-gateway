# MQTT Gateway

[![Build Status][travis-img]][travis]

MQTT Gateway is a VerneMQ plugin with token based (OAuth2 Bearer Token)
authentication on connect and topic based authorization on publish/subscribe
based on conventions and dynamic rules.



### Overview

#### Authentication

| Name           |   Type |  Default | Description |
| -------------- | ------ | -------- | ----------- |
| MQTT_CLIENT_ID | String | required | Concatenate your account identifier and a label into the agent identifier `${ACCOUNT_ID}.${LABEL}` |
| MQTT_PASSWORD  | String | optional | The value is currently ignored |
| MQTT_USERNAME  | String | optional | The value is currently ignored |



### How To Use

To build and start playing with the application,
execute following shell commands within different terminal tabs:

```bash
## To build container locally
docker build -t manifesthub/mqtt-gateway -f docker/Dockerfile .
## Running a container with VerneMQ and the plugin
docker run -p1883:1883 -ti --rm manifesthub/mqtt-gateway
## Publishing a message to the broker
MQTT_CLIENT_ID='00000000-0000-1000-a000-000000000000.example' \
    && mosquitto_pub -h $(docker-machine ip) -i "${MQTT_CLIENT_ID}" -t foo -m bar
```



## Troubleshooting

MQTT Gateway should be built using the same release version of Erlang/OTP as VerneMQ.



### License

The source code is provided under the terms of [the MIT license][license].

[travis]:https://travis-ci.org/netology-group/mqtt-gateway?branch=master
[travis-img]:https://secure.travis-ci.org/netology-group/mqtt-gateway.png?branch=master
[license]:http://www.opensource.org/licenses/MIT
