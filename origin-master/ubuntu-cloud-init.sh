#! /bin/bash

ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
REGION=`echo ${ZONE} | sed 's/[a-z]$//'`
ORIGIN_ARTIFACT="s3://dstcorp/artifacts/openshift-3.6.0.tar.gz"

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
# install dependencies of Openshift + curl + tcpdump and nano for troubleshooting
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

# create a non-privileged origin user
sudo adduser --system --home /var/lib/origin --gecos 'Openshift Origin,,,' --disabled-password openshift

# install & configure Openshift master
aws s3 cp ${ORIGIN_ARTIFACT} /tmp/origin.tar.gz \
    && mkdir /tmp/bin \
    && sudo tar xvfz /tmp/origin.tar.gz --directory /usr/local/bin --strip-components 1 \
    && sudo rm /usr/local/bin/README.md /usr/local/bin/LICENSE \
    && sudo mkdir -p /usr/local/etc/origin \
    && sudo chown openshift /usr/local/etc/origin \
    && sudo chown root.root /usr/local/bin/*

# set up the aws.conf file
echo "[Global]"        >/tmp/aws.conf
echo "Zone = ${ZONE}" >>/tmp/aws.conf
sudo cp /tmp/aws.conf /usr/local/etc/origin/aws.conf

# route DNS requests to listener on port 8053
# note: need to save iptables across reboots via ifconfig up/down
sudo iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 8053
sudo iptables-save >/tmp/iptables.conf
sudo cp /tmp/iptables.conf /etc
cat <<"EOF" >/tmp/iptables
#! /usr/bin/env bash
iptables-restore < /etc/iptables.conf
EOF
chmod +x /tmp/iptables
sudo cp /tmp/iptables /etc/network/if-up.d/iptables

# set up the systemd service file for the openshift service
cat <<"EOF" >/tmp/openshift.service
[Unit]
Description=Openshift Master

[Service]
User=openshift
Group=nogroup
ExecStart=/usr/local/bin/openshift-master-start
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/openshift.service /etc/systemd/system/openshift-master.service
sudo systemctl daemon-reload

# set up the startup script for etcd
cat <<"EOF" >/tmp/openshift-master-start
#! /bin/bash

REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//'`
CONFIG_DIR=/usr/local/etc/origin
ETCD_SERVER=https://10.10.128.10:2379
INTERNAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
CLUSTER_NAME=vpc0
OPENSHIFT_CONFIG=https://config.dstcorp.io/openshift/default/master/openshift/master/master-config.yaml
OPENSHIFT_HTPASSWD=https://config.dstcorp.io/openshift/default/master/openshift/htpasswd

source /etc/default/openshift-master

function fetchFile {
URL=$1
FILE=$2

    curl -sL ${URL} -o ${FILE}
    if [[ $? != 0 ]]; then
        echo "Warning: Unable to retrieve ${URL}; trying again in 2 minutes"
        sleep 120

        curl -sL ${URL} -o ${FILE}
        rc=$?
        if [[ $rc != 0 ]]; then
            echo "Error: Unable to retrieve ${URL}; Error $rc."
            exit $rc
        fi
    fi
}

if [[ ! -d ${CONFIG_DIR}/master ]]; then
    aws --region ${REGION} s3 cp s3://dstcorp/${CLUSTER_NAME}/config.tar.gz /tmp
    mkdir -p ${CONFIG_DIR}/master
    tar xvfz /tmp/config.tar.gz --directory ${CONFIG_DIR}/master --strip-components 2 openshift.local.config/master
    rm /tmp/config.tar.gz
fi

fetchFile ${OPENSHIFT_CONFIG} ${CONFIG_DIR}/master/master-config.yaml
fetchFile ${OPENSHIFT_HTPASSWD} ${CONFIG_DIR}/htpasswd

OPTS="--config ${CONFIG_DIR}/master/master-config.yaml"

exec /usr/local/bin/openshift start master ${OPTS}
EOF
chmod +x /tmp/openshift-master-start
sudo cp /tmp/openshift-master-start /usr/local/bin/openshift-master-start

# make it easy to work with Openshift after ssh'ing in
cat <<EOF >$HOME/.bash_aliases
alias oc='sudo /usr/local/bin/oc --config /usr/local/etc/origin/master/admin.kubeconfig'
EOF

# clean up
sudo apt-get autoremove
sudo apt-get clean
sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
