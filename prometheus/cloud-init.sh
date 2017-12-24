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

# install & configure ETCD
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

# clean up
rm -r /tmp/*

echo 'Disk Summary after Update'
df -H
