#! /bin/bash

ETCD_VERSION=v3.2.10
ETCD_ARTIFACT="s3://dstcorp/artifacts/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

# create a non-privileged etcd user
sudo adduser --system --home /var/lib/etcd --gecos 'etcd,,,' --disabled-password etcd

# install & configure ETCD
echo 'Starting etcd installation'
aws s3 cp ${ETCD_ARTIFACT} /tmp/etcd.tar.gz \
    && cd /tmp && tar xfz /tmp/etcd.tar.gz && cd - \
    && chmod +x /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd* \
    && sudo mv /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin \
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
CLIENT_CA=/usr/local/share/ca-certificates/dst-root.crt
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

if [[ "${CLIENT_CA}" == "dstroot.crt" ]]; then
    CLIENT_CA=/usr/local/share/ca-certificates/dst-root.crt
else
    client_ca=/usr/local/etc/etcd/client-ca.crt
    if [[ ! -f ${client_ca} ]]; then
        aws --region ${REGION} s3 cp ${CLIENT_CA} ${client_ca}
    fi
    CLIENT_CA=${client_ca}
fi

OPTS="--name ${NODE_NAME} \
  --cert-file=${CERT} \
  --key-file=${KEY} \
  --peer-cert-file=${CERT} \
  --peer-key-file=${KEY} \
  --trusted-ca-file=${CA} \
  --peer-trusted-ca-file=${CA} \
  --peer-client-cert-auth \
  --trusted-ca-file=${CLIENT_CA} \
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

# clean up
rm -r /tmp/*

echo 'Disk Summary after Update'
df -H
