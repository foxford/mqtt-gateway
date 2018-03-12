FROM ubuntu:16.04
RUN apt-get update && apt-get install -y coturn && mkdir /secret

COPY ./run.sh /
#/usr/bin/turnserver -c /etc/turnserver.conf --pidfile /var/run/
COPY ./secret/fullchain.pem /secret/
COPY ./secret/privkey.pem /secret



#min port
ENV min_port='min-port='
ENV min_port_value='49152'

#max port
ENV max_port='max-port='
ENV max_port_value='49252'

#tls port
ENV tls_port='tls-listening-port='
ENV tls_port_value='5349'

#secrets
ENV cert='cert='
ENV cert_p='/secret/fullchain.pem'
ENV pkey='pkey='
ENV pkey_p='/secret/privkey.pem'

ENV ext_ip='external-ip=' 
ENV ext_ip_v='35.197.241.108'

RUN sed -i "s/^.*${min_port}.*\$/${min_port}${min_port_value}/g" /etc/turnserver.conf && \
    sed -i "s/^.*${max_port}.*\$/${max_port}${max_port_value}/g" /etc/turnserver.conf && \
    #sed -i "0,/^.*${aux}.*\$/s//${aux}${aux_value}/" /etc/turnserver.conf && \
    sed -i "0,/^.*${tls_port}.*\$/s//${tls_port}${tls_port_value}/" /etc/turnserver.conf && \
    sed -i "0,/^.*${cert}.*\$/s@@${cert}${cert_p}@" /etc/turnserver.conf && \
    sed -i "0,/^.*${pkey}.*\$/s@@${pkey}${pkey_p}@" /etc/turnserver.conf && \
    echo "" >> /etc/turnserver.conf && \
    echo 'verbose' >> /etc/turnserver.conf && \
 
    chmod +x /run.sh 

EXPOSE 0.0.0.0:3478:3478  0.0.0.0:5349:5349  0.0.0.0:49152-49252:49152-49252  0.0.0.0:3478:3478/udp  0.0.0.0:5349:5349/udp   0.0.0.0:49152-49252:49152-49252/udp
CMD ["/run.sh"]
