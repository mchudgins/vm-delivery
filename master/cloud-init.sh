#! /bin/bash

VERSION=3.6.1
ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
REGION=`echo ${ZONE} | sed 's/[a-z]$//'`
ORIGIN_ARTIFACT="s3://dstcorp/artifacts/origin-${VERSION}.tar.gz"

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

# create a non-privileged origin user
sudo adduser --system --home /var/lib/origin --gecos 'Openshift Origin,,,' --disabled-password openshift

# install & configure Openshift master
aws s3 cp ${ORIGIN_ARTIFACT} /tmp/origin.tar.gz \
    && mkdir /tmp/bin \
    && sudo tar xvfz /tmp/origin.tar.gz --directory /usr/local/bin \
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

aws s3 cp s3://dstcorp/${CLUSTER_NAME}/${CERT_NAME}.crt ${CONFIG_DIR}
aws s3 cp s3://dstcorp/${CLUSTER_NAME}/${CERT_NAME}.key ${CONFIG_DIR}
chown openshift ${CONFIG_DIR}/${CERT_NAME}.*
chmod 0400 ${CONFIG_DIR}/${CERT_NAME}.key

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
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
