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
VAULT_TOKEN=`sed -e 's/^Unseal.*$//g' -e 's/^Initial Root Token: //' | tr -d '\n'`
VAULT_ADDR="https://vault-seed-${REGION}.dstcorp.io:8200/"

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
        echo -e "\nVault has not been unsealed yet.  You must unseal vault prior to running this script.\n"
    fi
    exit $rc
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


echo "deploying the certificate & key"
vault write secret/etcd/seed-cluster cert=@${cert}
# read it back with
#   vault read -format=json secret/etcd/seed-cluster | jq .data.cert | sed -e 's/"//g' -e 's/\\n/\n/g'
#       or
#   vault read -field=key secret/etcd/seed-cluster
rc=$?
if [[ $rc != 0 ]]; then
    echo -e "\nError encountered writing/updating the certificate to Vault\n"
    exit $rc
fi

vault write secret/etcd/seed-cluster key=@${key}
# read it back with
#   vault read -format=json secret/etcd/seed-cluster | jq .data.key | sed -e 's/"//g' -e 's/\\n/\n/g'
rc=$?
if [[ $rc != 0 ]]; then
    echo -e "\nError encountered writing/updating the key to Vault\n"
    exit $rc
fi

echo -e "\nDeployment complete.\n"

#
# enable aws authentication use ec2 instance metadata & associate pkcs7 signature
#
#vault auth-enable aws
#vault write auth/aws/role/vault-seed-role auth_type=ec2 bound_ami_id=${VAULT_AMI} policies=default,test max_ttl=30m
