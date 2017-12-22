#!/usr/bin/env bash
#
# Usage:  deployEtcdCertToVault.sh <cert filename> <key filename>
#
# This file reads stdin for the "vault.keys" file which is expected to be of the format
#
# Unseal Key 1: <some gibberish>
# Unseal Key 2: <some gibberish>
#        .
#        .
# Unseal Key N: <some gibberish>
# Initial Root Token: <the thing we want>
#
# example:
#   cat vault.keys | deployEtcdCertToVault.sh cert.pem key.pem

REGION=`aws configure get region`
VAULT_AMI="ami-169a316c"

VAULT_ADDR="https://vault.dst.cloud"

# process the vault.keys
read line
key1=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`
echo "key: " ${key1}

read line
key2=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`
echo "key: " ${key2}

read line
key3=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`
echo "key: " ${key3}

read line
key4=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`
echo "key: " ${key4}

read line
key5=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`
echo "key: " ${key5}

read line
token=`echo ${line} | sed -e 's/^Initial Root Token:  //'`
VAULT_TOKEN=${token}

# make sure we got enuf on the cli
if [[ $# -ne 2 ]]; then
    echo -e "\nUsage: `basename $0`" '<cert filename>' '<key filename>' "\n"
    exit 1
fi

cert=$1
key=$2

if [[ ! -f ${cert} ]]; then
    echo -e "\nThe first parameter, ${cert}, does not appear to be a file!\n"
    exit 1
fi

if [[ ! -f ${key} ]]; then
    echo -e "\nThe first parameter, ${key}, does not appear to be a file!\n"
    exit 1
fi

vault status
rc=$?
if [[ $rc != 0 ]]; then
    if [[ $rc == 2 ]]; then
        echo -e "\nVault has not been unsealed yet.  Proceeding with unseal operations.\n"
        vault unseal -address=${VAULT_ADDRESS} ${key1}
        vault unseal -address=${VAULT_ADDRESS} ${key2}
        vault unseal -address=${VAULT_ADDRESS} ${key3}
    fi
fi

#
# vault url convention
#
# certificates:
#
#   /secret/certificates/<certificate domain name>
#
#   Example:  url of the certificate for etcd.dst.cloud
#       /secret/certificates/etcd.dst.cloud
#
#   Example:  url of the certificate for *.dst.cloud
#       /secret/certificates/star.dst.cloud
#

# establish access polices
FILE=`mktemp`
cat <<EOF >${FILE}
path "secret/certificates/*" {
  capabilities = [ "read", "list"]
}
EOF

vault write-policy certificate-reader ${FILE}

echo "deploying the etcd certificate key"

# read it back with
#   vault read -format=json secret/certificates/etcd.dst.cloud | jq .data.key | sed -e 's/"//g' -e 's/\\n/\n/g'
#       or
#   vault read -field=key secret/certificates/etcd.dst.cloud
vault write secret/certificates/etcd.dst.cloud key=@${key}
rc=$?
if [[ $rc != 0 ]]; then
    echo -e "\nError encountered writing/updating the etcd.dst.cloud key to Vault\n"
    exit $rc
fi

echo -e "\nDeployment complete.\n"

#
# enable aws authentication use ec2 instance metadata & associate pkcs7 signature
#
#vault auth-enable aws
#vault write auth/aws/role/vault-seed-role auth_type=ec2 bound_ami_id=${VAULT_AMI} policies=certificate-reader max_ttl=30m
