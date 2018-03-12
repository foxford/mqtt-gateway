# TURN

## Table of contents
1. Overview 
2. Installation
   - Preferences
   - Static IP
   - Domain name
   - Certificate
   - Build docker image
   - Push in the repository
   - Gcloud compute COS host(deploy image)
   - Label
   - Firewall rules
3. Maintenance

### Overview

Signal's apps need to TURN/STUN for working across Net. This mean that clients can't send traffic over Internet directly and can't connect and in this case they can be appropriate STUN for self-discovering and TURN for sending traffic beyond NAT.

Our TURN and STUN is one thing application based on  [COTURN](https://github.com/coturn/coturn). 

App work inside docker container.


We selected [Gcloud compute platform](https://cloud.google.com/compute/docs/gcloud-compute/) wtih [cos](https://cloud.google.com/sdk/gcloud/reference/beta/compute/instances/create-with-container) for deployment.

### Installation

#### Preferences

At first switch to prefered gcloud project.
Check sign-in docker repository. 

#### Static IP and NS.
Are needed for run server.

For test suite: mqtt.testing.netology-group.services (current).

If profided by AWS: 

Hosted zone: netology-group.services,
record set: type 'A', name 'mqtt.testing'.

#### Certificate

For generation TLS certificate we use [Certbot](https://certbot.eff.org/).
You must [install](https://certbot.eff.org/docs/install.html) him.

If you don't have certificate:
Further you need to  copy generated files **cert.pem** and **fullchain.pem**  to nested directory **secret**.

if certificate was been generated:

Retrive files **cert.pem** and **fullchain.pem** to nested directory **secret**.

#### Build docker image

Get docker files from repository, change env "ext_ip_v" by your's static IP and build image, example(test domain name):

docker build -t eu.gcr.io/netology-group/turn:latest

#### Push in the repository

docker push eu.gcr.io/netology-group/turn:latest

#### Gcloud compute COS host(deploy image)



We can deploy docker image with [COS](https://cloud.google.com/container-optimized-os/docs/): 

list instances: `gcloud compute instances list`

create instance:
 
>```
> gcloud beta compute instances create-with-container  ${NAME:-'mediaturn'} \
> --container-image ${IMAGE:-eu.gcr.io/netology-group/coturn\:latest} \
> --machine-type ${MACH_TYPE:-'n1-standard-1'} \
> --address ${WHITE_IP:-'turn'} \
> --zone europe-west2-b \
> --can-ip-forward 
>```

#### Label

`gcloud beta compute instances add-tags ${NAME:-'mediaturn'} --tags=${TAG:-'mediaturn'}`

#### Firewall rules

Create firewall rules
 
Ingress ports access: 
> ```
> gcloud compute firewall-rules create ${RULE1:-'mediaturn1'} \
> --direction ingress \
> --source-ranges '0.0.0.0/0' \
> --allow UDP:49152-49252,TCP:49152-49252,TCP:3478,UDP:3478,TCP:3478 \
> --target-tags ${TAG:-'mediaturn'}
> ```
 
Egress ports access: 
> ```
>gcloud compute firewall-rules create ${RULE2:-'mediaturn2'} \
> --direction egress \
> --destination-ranges '0.0.0.0/0' \
> --allow UDP:49152-49252,TCP:49152-49252,TCP:3478,UDP:3478,TCP:3478 \
> --target-tags ${TAG:-'mediaturn'}
>```

### Maintenance

Certificate will be expired after 3 months(strong). Certificate expireted warnings  will be sending via email. We able to renew him. Action to [renew](https://certbot.eff.org/docs/using.html#renewing-certificates). 


