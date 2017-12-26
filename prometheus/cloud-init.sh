#! /bin/bash

PROM_VERSION="2.0.0"
PROM_ARTIFACT="s3://dstcorp/artifacts/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

# create a non-privileged prometheus user
sudo adduser --system --home /var/lib/prometheus --gecos 'prometheus,,,' --disabled-password prometheus

# create a non-privileged promproxy user
sudo adduser --system --home /var/lib/proxy --gecos 'prometheus proxy,,,' --disabled-password promproxy

# install & configure Prometheus
echo 'Starting prometheus installation'
aws s3 cp ${PROM_ARTIFACT} /tmp/prom.tar.gz \
    && cd /tmp && tar xfz /tmp/prom.tar.gz && cd - \
    && chmod +x /tmp/prometheus-${PROM_VERSION}.linux-amd64/prom* \
    && sudo mv /tmp/prometheus-${PROM_VERSION}.linux-amd64/prometheus /usr/local/bin \
    && sudo mkdir -p /usr/local/etc/prometheus \
    && sudo chown prometheus /usr/local/etc/prometheus \
    && sudo mkdir -p /var/lib/prometheus \
    && sudo chown prometheus /var/lib/prometheus \
    && sudo chown root.root /usr/local/bin/*

# install & configure the reverse proxy
echo 'Starting proxy installation'
aws s3 cp s3://dstcorp/artifacts/playground /tmp/playground \
    && cd /tmp \
    && chmod +x /tmp/playground \
    && sudo cp /tmp/playground /usr/local/bin \
    && sudo mkdir -p /usr/local/etc/proxy \
    && sudo chown promproxy /usr/local/etc/proxy \
    && sudo mkdir -p /var/lib/proxy \
    && sudo chown promproxy /var/lib/proxy \
    && sudo chown root.root /usr/local/bin/*

# set up the systemd service file for the prometheus service
cat <<"EOF" >/tmp/prometheus.service
[Unit]
Description=Prometheus metrics service

[Service]
#EnvironmentFile=-/etc/default/prometheus
User=prometheus
Group=nogroup
ExecStart=/usr/local/bin/prometheus-start --config.file=/usr/local/etc/prometheus/prometheus.yml
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/prometheus.service /etc/systemd/system

# set up the systemd service file for the proxy service
cat <<"EOF" >/tmp/promproxy.service
[Unit]
Description=prometheus proxy service

[Service]
#EnvironmentFile=-/etc/default/prometheus
User=promproxy
Group=nogroup
ExecStart=/usr/local/bin/proxy-start
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/promproxy.service /etc/systemd/system
sudo systemctl daemon-reload

# set up the startup script for prometheus
cat <<"EOF" >/tmp/prometheus-start
#! /usr/bin/env bash

if [[ -f /etc/default/prometheus ]]; then
    source /etc/default/prometheus
fi

if [[ ! -f /usr/local/prometheus/prometheus.yml ]]; then
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//'`

# set up the config for prometheus
cat <<EOF_YML >/tmp/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node'

    ec2_sd_configs:
    - region: ${REGION}
      port: 9100

    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: Name
      - source_labels: [__meta_ec2_tag_instance_id]
        target_label: instanceId
      - source_labels: [__meta_ec2_tag_availability_zone]
        target_label: AZ
EOF_YML
cp /tmp/prometheus.yml /usr/local/etc/prometheus
fi

exec /usr/local/bin/prometheus --config.file=/usr/local/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/
EOF
chmod +x /tmp/prometheus-start
sudo cp /tmp/prometheus-start /usr/local/bin

# set up the startup script for the proxy
cat <<"EOF" >/tmp/proxy-start
#! /usr/bin/env bash

S3_CERT=s3://dstcorp/certificates/star.dstcorp.io.pem

if [[ -f /etc/default/proxy ]]; then
    source /etc/default/proxy
fi

if [[ ! -f /usr/local/etc/proxy/cert.pem ]]; then
    aws s3 cp ${S3_CERT} /usr/local/etc/proxy/cert.pem
fi

if [[ ! -f /usr/local/etc/proxy/key.pem ]]; then
    /usr/local/bin/vault-get-cert star.dstcorp.io >/usr/local/etc/proxy/key.pem
    if [[ $? -ne 0 ]]; then
        echo "Unable to obtain certificate from vault instance: " code=$? ${vault_response}
        exit 1
    fi
    chmod go-rw /usr/local/etc/proxy/key.pem
    chmod u-w /usr/local/etc/proxy/key.pem
fi

exec /usr/local/bin/playground reverse-proxy http://localhost:9090 \
    --port :8443 \
    --cert /usr/local/etc/proxy/cert.pem \
    --key /usr/local/etc/proxy/key.pem
EOF
chmod +x /tmp/proxy-start
sudo cp /tmp/proxy-start /usr/local/bin

# route requests for the proxy on port 443 to listener on port 8443
# note: need to save iptables across reboots via ifconfig up/down
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
sudo iptables-save >/tmp/iptables.conf
sudo cp /tmp/iptables.conf /etc
cat <<"EOF" >/tmp/iptables
#! /usr/bin/env bash
iptables-restore < /etc/iptables.conf
EOF
chmod +x /tmp/iptables
sudo cp /tmp/iptables /etc/network/if-up.d/iptables

# clean up
rm -r /tmp/*

echo 'Disk Summary after Update'
df -H
