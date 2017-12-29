#! /bin/bash

VAULT_ARTIFACT="s3://dstcorp/artifacts/vault-0.9.1"
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

# create a non-privileged user to run the generator script
sudo adduser --system --home /var/lib/configGen --gecos 'Cluster Configuration Generator,,,' --disabled-password configGen

# install VAULT
aws --region ${REGION} s3 cp ${VAULT_ARTIFACT} /tmp/vault \
    && chmod +x /tmp/vault \
    && sudo mv /tmp/vault /usr/local/bin \
    && sudo chown -R configGen /var/lib/configGen

# install Openshift
aws --region ${REGION} s3 cp ${ORIGIN_ARTIFACT} /tmp/origin.tar.gz \
    && mkdir /tmp/bin \
    && sudo tar xvfz /tmp/origin.tar.gz --directory /usr/local/bin \
    && sudo chown root.root /usr/local/bin/*

# create the config generator script
cat <<"EOF" >/tmp/configGen
#! /bin/bash
HOME=/var/lib/configGen
VAULT_ADDR=https://vault.dst.cloud
S3KEYS=s3://io.dstcorp.vault.o7t-alpha/vault.keys
S3CABUNDLE=s3://dstcorp/certificates/ucap-ca-bundle.pem
REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone \
    | sed -e 's/[abcdefghijk]$//' -e 's/"//g'`
REPO=https://git-codecommit.us-east-1.amazonaws.com/v1/repos/testRepo
AGENT_EMAIL="cluster-config-generator@dstcorp.io"
AGENT_NAME="Cluster Config Generator"
CLUSTER=vpc0

if [[ -f /etc/default/configGen ]]; then
    source /etc/default/configGen
fi

export VAULT_ADDR
printenv | sort
echo "pwd: " `pwd`

aws s3 cp ${S3CABUNDLE} ~/ca-bundle.pem
if [[ ! -f ~/ca-bundle.pem ]]; then
    echo "Unable to download ${S3CABUNDLE} to ca-bundle.pem!"
    exit 1
fi

aws s3 cp ${S3KEYS} /tmp/keys
token=`cat /tmp/keys | grep -i "Initial Root Token" | sed -e 's/^Initial Root Token: //'`
if [[ -z "${token}" || "${token}" == null ]]; then
    echo "Unable to parse vault token from ${S3KEYS}!"
    exit 1
fi
export VAULT_TOKEN=${token}
rm /tmp/keys

# clone the repo and configure it for commits
git config --global user.email "${AGENT_EMAIL}"
git config --global user.name "${AGENT_NAME}"
git clone --config credential.helper="!aws --region=${REGION} codecommit credential-helper $@" \
    --config credential.UseHttpPath=true \
    ${REPO}
if [[ $? -ne 0 ]]; then
    echo "Unable to clone ${REPO}. Exiting."
    exit 1
fi

cd `basename ${REPO}`
if [[ ! -d ${CLUSTER} ]]; then
    mkdir ${CLUSTER}
fi

cd ${CLUSTER}

# create a cert for the etcd instances

etcd=`vault write -format=json ucap/issue/dst-cloud common_name=etcd-${CLUSTER}.dst.cloud \
    alt_names="etcd0-${CLUSTER}.dst.cloud,etcd1-${CLUSTER}.dst.cloud,etcd2-${CLUSTER}.dst.cloud,etcd3-${CLUSTER}.dst.cloud,etcd4-${CLUSTER}.dst.cloud"`

vault write secret/certificates/etcd-${CLUSTER}.dst.cloud key="`echo ${etcd} | jq -r .data.private_key`"
if [[ $? -eq 0 ]]; then
    echo ${etcd} | jq -r .data.certificate >etcd-${CLUSTER}.dst.cloud.pem
    cat ~/ca-bundle.pem >>etcd-${CLUSTER}.dst.cloud.pem
    git add etcd-${CLUSTER}.dst.cloud.pem
fi

# all done, commit the repo's changes
git commit -m "Updating ${CLUSTER} with new configuration."
git push origin master

EOF
chmod +x /tmp/configGen
sudo cp /tmp/configGen /usr/local/bin

# clean up
sudo apt-get clean
sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
