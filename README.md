# MQTT Gateway

MQTT Gateway is a VerneMQ plugin with token based (OAuth2 Bearer Token)
authentication on connect and topic based authorization on publish/subscribe
based on conventions and dynamic rules.



### How To Use

To build and start playing with the application,
execute following shell commands within different terminal tabs:

```bash
## To build container locally
docker build -t manifesthub/mqtt-gateway -f docker/Dockerfile .
## Running a container with VerneMQ and the plugin
docker run -p1883:1883 -ti --rm manifesthub/mqtt-gateway
## Publishing a message to the broker
mosquitto_pub -h $(docker-machine ip) -t foo -m bar
```



### License

The source code is provided under the terms of [the MIT license][license].

[license]:http://www.opensource.org/licenses/MIT
