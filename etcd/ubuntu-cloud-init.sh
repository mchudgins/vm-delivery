#! /bin/bash

VAULT_ARTIFACT="s3://dstcorp/artifacts/vault-0.8.3.zip"
ETCD_ARTIFACT="s3://dstcorp/artifacts/etcd-3.2.7-custom"

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

#   update package info
sudo apt-get update -yq

# the grub package doesn't respect -y by itself, so we need a bunch of extra options,
# or the provisioner will get stuck at an interactive prompt asking about Grub configuration
# see http://askubuntu.com/questions/146921/how-do-i-apt-get-y-dist-upgrade-without-a-grub-config-prompt
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -yq
sudo apt-get install -yq --no-install-recommends \
  apt-transport-https awscli \
  bash-completion ca-certificates curl e2fsprogs ethtool htop jq \
  linux-image-extra-virtual nano \
  net-tools tcpdump unzip

# stop unattended upgrades -- that's why we have baked images!
sudo apt-get remove -yq unattended-upgrades
sudo apt-get autoremove -yq

# DST Root CA
aws s3 cp s3://dstcorp/dst-root.crt /tmp
sudo cp /tmp/dst-root.crt /usr/local/share/ca-certificates
sudo update-ca-certificates

# change the journald options to have only one log file
# rather than one per user
sudo sh -c 'echo "SplitMode=none" >>/etc/systemd/journald.conf'

# create a non-privileged etcd user
sudo adduser --system --home /var/lib/etcd --gecos 'etcd,,,' --disabled-password etcd

# install & configure VAULT as a single (non-HA) instance using s3 as the backing storage
aws s3 cp ${VAULT_ARTIFACT} /tmp/vault.zip \
    && unzip /tmp/vault.zip \
    && sudo mv vault /usr/local/bin \
    && aws s3 cp ${ETCD_ARTIFACT} /tmp/etcd \
    && chmod +x /tmp/etcd \
    && sudo mv /tmp/etcd /usr/local/bin \
    && sudo mkdir -p /usr/local/etc/etcd \
    && sudo chown etcd /usr/local/etc/etcd \
    && sudo mkdir -p /var/lib/etcd \
    && sudo chown etcd /var/lib/etcd \
    && sudo chown root.root /usr/local/bin/*

# set up the systemd service file for the etcd service
cat <<"EOF" >/tmp/etcd.service
[Unit]
Description=etcd distributed consensus service

[Service]
#EnvironmentFile=-/etc/default/etcd
User=etcd
Group=nogroup
ExecStart=/usr/local/bin/etcd-start
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/etcd.service /etc/systemd/system
sudo systemctl daemon-reload

# set up the startup script for etcd
cat <<"EOF" >/tmp/etcd-start
#! /bin/bash

CA=/usr/local/share/ca-certificates/dst-root.crt
CERT=/usr/local/etc/etcd/cert.pem
KEY=/usr/local/etc/etcd/key.pem
INTERNAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
CLUSTER_NAME=vpc0

source /etc/default/etcd

if [[ ! -f ${CERT} ]]; then
    aws --region ${REGION} s3 cp s3://dstcorp/etcd/cert.pem ${CERT}
fi

if [[ ! -f ${KEY} ]]; then
    aws --region ${REGION} s3 cp s3://dstcorp/etcd/key.pem  ${KEY}
    chmod og-rw /usr/local/etc/etcd/key.pem
    chmod u-w /usr/local/etc/etcd/key.pem
fi

OPTS="--name ${NODE_NAME} \
  --cert-file=${CERT} \
  --key-file=${KEY} \
  --peer-cert-file=${CERT} \
  --peer-key-file=${KEY} \
  --trusted-ca-file=${CA} \
  --peer-trusted-ca-file=${CA} \
  --peer-client-cert-auth \
  --client-cert-auth \
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \
  --listen-peer-urls https://${INTERNAL_IP}:2380 \
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \
  --advertise-client-urls https://${INTERNAL_IP}:2379 \
  --initial-cluster-token ${CLUSTER_NAME} \
  --initial-cluster ${INITIAL_CLUSTER} \
  --initial-cluster-state new \
  --data-dir=/var/lib/etcd"

exec /usr/local/bin/etcd ${OPTS}
EOF
chmod +x /tmp/etcd-start
sudo cp /tmp/etcd-start /usr/local/bin/etcd-start

# create the rc.local start script
cat <<"EOF" >/tmp/rc.local
#! /bin/bash
hostname `hostname -s`.ec2.internal

if [[ ! -f /etc/default/etcd ]]; then
    REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[abcdefghijk]$//'`

    # create the initial config for the seed instance of vault
    # (normally we should use spring cloud config server for this,
    # but it won't be running yet!)
cat <<EOF_CFG >/etc/default/etcd
EOF_CFG

    aws --region ${REGION} s3 cp s3://io.dstcorp.vault.${REGION}/cert.pem /usr/local/etc/etcd/cert.pem
    aws --region ${REGION} s3 cp s3://io.dstcorp.vault.${REGION}/key.pem /usr/local/etc/etcd/key.pem
    chmod og-rw /usr/local/etc/etcd/key.pem
    chmod u-w /usr/local/etc/etcd/key.pem
    chown -R etcd /usr/local/etc/etcd
fi

if [[ -f /tmp/etcd-config ]]; then
    cp /tmp/etcd-config /tmp/found.it
else
    date > /tmp/not.found
fi

systemctl start etcd
EOF
#sudo cp /tmp/rc.local /etc/rc.local
#sudo chmod +x /etc/rc.local

# clean up
sudo apt-get autoremove
sudo apt-get clean
sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
