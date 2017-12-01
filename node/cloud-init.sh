#! /bin/bash

VERSION=3.6.1
ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
REGION=`echo ${ZONE} | sed 's/[a-z]$//'`
ORIGIN_ARTIFACT="s3://dstcorp/artifacts/origin-${VERSION}.tar.gz"

# hmmmm, need to set the hostname to something the AWS DNS server knows
NODENAME=`hostname -s`
sudo hostname ${NODENAME}.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

# install dependencies of Openshift + curl + tcpdump and nano for troubleshooting
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    install -yq --no-install-recommends openvswitch-switch

# docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
# docker-ce broken with ubuntu 17.10, see https://gist.github.com/levsthings/0a49bfe20b25eeadd61ff0e204f50088
#
#sudo add-apt-repository \
#   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
#   $(lsb_release -cs) \
#   stable"
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu zesty stable"
sudo apt-get update
sudo apt-get install -yq --no-install-recommends docker-ce
sudo sed -i 's|ExecStart.*|ExecStart=/usr/bin/dockerd -H fd:// --insecure-registry=172.30.0.0/16 --exec-opt native.cgroupdriver=systemd|g' \
    /lib/systemd/system/docker.service
sudo systemctl daemon-reload
sudo systemctl enable docker

# create a non-privileged origin user
sudo adduser --system --home /var/lib/origin --gecos 'Openshift Origin,,,' --disabled-password openshift
sudo addgroup openshift docker

# install & configure Openshift node
aws s3 cp ${ORIGIN_ARTIFACT} /tmp/origin.tar.gz \
    && sudo tar xvfz /tmp/origin.tar.gz --directory /usr/local/bin \
    && sudo mkdir -p /opt/cni/bin \
    && sudo ln -s /usr/local/bin/host-local /opt/cni/bin \
    && sudo ln -s /usr/local/bin/loopback /opt/cni/bin \
    && sudo ln -s /usr/local/bin/sdn-cni-plugin /opt/cni/bin/openshift-sdn \
    && sudo mkdir -p /usr/local/etc/origin \
    && sudo chown openshift /usr/local/etc/origin \
    && sudo chown root.root /usr/local/bin/*

# set up the aws.conf file
echo "[Global]"        >/tmp/aws.conf
echo "Zone = ${ZONE}" >>/tmp/aws.conf
sudo cp /tmp/aws.conf /usr/local/etc/origin/aws.conf

# set up the systemd service file for the openshift service
cat <<"EOF" >/tmp/openshift.service
[Unit]
Description=Openshift Node

[Service]
#User=openshift
Group=nogroup
ExecStartPre=/usr/local/bin/openshift-node-start
ExecStart=/usr/local/bin/openshift start node --config /usr/local/etc/origin/node/node-config.yaml
ExecReload=/bin/kill -HUP $MAINPID
WorkingDirectory=/var/lib/origin
KillMode=process
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/openshift.service /etc/systemd/system/openshift-node.service
sudo systemctl daemon-reload

# set up the startup script for etcd
cat <<"EOF" >/tmp/openshift-node-start
#! /bin/bash

REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//'`
CONFIG_DIR=/usr/local/etc/origin
INTERNAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
CLUSTER_NAME=vpc0
NODE_NAME=`hostname -s`
HOSTNAME=`hostname`
OPENSHIFT_CONFIG=https://config.dstcorp.io/openshift/default/master/openshift/node/node-config.yaml

source /etc/default/openshift-node

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

if [[ ! -d ${CONFIG_DIR}/node ]]; then
    aws --region ${REGION} s3 cp s3://dstcorp/${CLUSTER_NAME}/config.tar.gz /tmp
    mkdir -p ${CONFIG_DIR}/node
    tar xvfz /tmp/config.tar.gz --directory ${CONFIG_DIR}/node --strip-components 2 openshift.local.config/${NODE_NAME}
fi

fetchFile ${OPENSHIFT_CONFIG} ${CONFIG_DIR}/node/node-config.yaml
sed -e "s/nodeName:.*/nodeName: ${HOSTNAME}/g" -i ${CONFIG_DIR}/node/node-config.yaml
EOF
chmod +x /tmp/openshift-node-start
sudo cp /tmp/openshift-node-start /usr/local/bin/openshift-node-start

# clean up
#sudo apt-get autoremove
#sudo apt-get clean
#sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
