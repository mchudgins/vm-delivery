#! /bin/bash

VAULT_ARTIFACT="s3://dstcorp/artifacts/vault-0.9.1"

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

# create a non-privileged vault user
sudo adduser --system --home /var/lib/vault --gecos 'vault,,,' --disabled-password vault

# install & configure VAULT as a single (non-HA) instance using s3 as the backing storage
aws s3 cp ${VAULT_ARTIFACT} /tmp/vault \
    && chmod +x /tmp/vault \
    && sudo mv /tmp/vault /usr/local/bin \
    && sudo mkdir -p /usr/local/etc/vault \
    && sudo chown vault /usr/local/etc/vault \
    && sudo chown vault /usr/local/bin/vault \
    && sudo chown -R vault /var/lib/vault

# set up the systemd service file for the vault service
cat <<EOF >/tmp/vault.service
[Unit]
Description=Vault secrets management service
#After=network.target cloud-final.service
#Requires=network.target cloud-final.service

[Service]
#EnvironmentFile=-/etc/default/vault
User=vault
Group=nogroup
ExecStart=/usr/local/bin/vault-start
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/vault.service /etc/systemd/system
sudo systemctl daemon-reload

# route requests for Vault on port 443 to listener on port 8200
# note: need to save iptables across reboots via ifconfig up/down
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8200
sudo iptables-save >/tmp/iptables.conf
sudo cp /tmp/iptables.conf /etc
cat <<"EOF" >/tmp/iptables
#! /usr/bin/env bash
iptables-restore < /etc/iptables.conf
EOF
chmod +x /tmp/iptables
sudo cp /tmp/iptables /etc/network/if-up.d/iptables

# create the vault-start script
cat <<"EOF" >/tmp/vault-start
#! /bin/bash
VAULT_CONFIG=/usr/local/etc/vault/config.hcl
#hostname `hostname -s`.dst.cloud

if [[ ! -f ${VAULT_CONFIG}} ]]; then
    REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[abcdefghijk]$//'`
    if [[ -f /etc/default/vault ]]; then
        . /etc/default/vault
    fi

    # create the initial config for the seed instance of vault
    # (normally we should use spring cloud config server for this,
    # but it won't be running yet!)
cat <<EOF_CFG >/tmp/config.hcl
storage "s3" {
  bucket = "${VAULT_BUCKET}"
  region = "${REGION}"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/usr/local/etc/vault/cert.pem"
  tls_key_file = "/usr/local/etc/vault/key.pem"
}
disable_mlock = "true"
pid_file = "/var/lib/vault/pid"
EOF_CFG

    cp /tmp/config.hcl ${VAULT_CONFIG}
    aws --region ${REGION} s3 cp s3://${VAULT_BUCKET}/cert.pem /usr/local/etc/vault/cert.pem
    aws --region ${REGION} s3 cp s3://${VAULT_BUCKET}/key.pem /usr/local/etc/vault/key.pem
    chmod og-rw /usr/local/etc/vault/key.pem
    chmod u-w /usr/local/etc/vault/key.pem
#    chown -R vault /usr/local/etc/vault
fi

# restore the iptables rules
#iptables-restore < /etc/iptables.conf

exec vault server -config=${VAULT_CONFIG}
EOF
chmod +x /tmp/vault-start
sudo cp /tmp/vault-start /usr/local/bin

#
# this script unseals the vault instance
#

cat <<"EOF" >/tmp/vault-prepare
#!/usr/bin/env bash

#
# a vault can server can be in one of three states:
# - uninitialized
# - sealed
# - unsealed
#
# this script detects the current state of a vault instance
# and puts it in the "unsealed" state.
#
# Usage:
#   vault-prepare <vault_address> <s3 object for vault keys>
#
# Example:
#   vault-prepare https://vault.local.dstcorp.io:8200 s3://dstcorp/vault-test.keys
#
# Upon successful completion:
# - vault will be in the unsealed state
# - the env var VAULT_TOKEN will have been exported and set to the value from the vault key file
#

function usage {
    echo "Usage:  `basename $0` <vault address> <s3 object for vault keys>"
}

if [[ -z "${VAULT_ADDR}" ]]; then
    if [[ -z "$1" ]]; then
        usage
        exit 1
    fi
    VAULT_ADDR=$1
    shift
fi

if [[ -z "$1" ]]; then
    usage
    exit 1
fi
S3KEYS=$1

VAULT=`which vault`
if [[ $? -ne 0 ]]; then
    echo "The 'vault' executable was not found on the path (${PATH})."
    echo "Please install vault."
    exit 1
fi

function initVault {
    keyFile=`mktemp`
    vault init >${keyFile}
    aws s3 cp ${keyFile} ${S3KEYS}
    rm ${keyFile}
}

function isSealed {
    statusFile=$1
    marker="Mode: sealed"
    result=`grep "${marker}" ${statusFile} | sed -e 's/^\t//'`
    if [[ "${result}" == "${marker}" ]]; then
        echo "sealed"
    else
        result=`grep "Sealed: false" ${statusFile}`
        if [[ "${result}" == "Sealed: false" ]]; then
            echo "unsealed"
        else
            echo "unknown"
        fi
    fi
}

function processKeyFile {
read line
key1=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`

read line
key2=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`

read line
key3=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`

read line
key4=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`

read line
key5=`echo ${line} | sed -e 's/^Unseal Key [0-9]://'`

read line
token=`echo ${line} | sed -e 's/^Initial Root Token:  //'`

vault unseal ${key1} >/dev/null 2>&1
vault unseal ${key2} >/dev/null 2>&1
vault unseal ${key3} >/dev/null 2>&1

echo ${token}
}

function unSeal {
    keyFile=`mktemp`
    aws s3 cp ${S3KEYS} ${keyFile} >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Unable to copy ${S3KEYS}"
        rm ${keyFile}
        exit 1
    fi

    token=`cat ${keyFile} | processKeyFile`

    rm ${keyFile}

    echo ${token}
}


# check the status of vault. if it hasn't been initialized, then initialize it.
statusFile=`mktemp`
${VAULT} status >${statusFile} 2>&1
# a non-zero result means that vault may be uninitialized
# check the statusFile for the line "* server is not yet initialized"
if [[ $? -ne 0 ]]; then
    marker="* server is not yet initialized"
    result=`grep "${marker}" ${statusFile}`
    if [[ $? -eq 0 && "${result}" == "${marker}" ]]; then
        echo Vault is not initialized. Initializing ${VAULT_ADDR}.
        initVault
    else
        result=`isSealed ${statusFile}`
        if [[ "${result}" != "sealed" ]]; then
            echo "Unexpected error (${result}) checking vault instance's status:"
            cat ${statusFile}
            exit 1
        fi
    fi
fi
rm ${statusFile}

# check the status of vault. if it hasn't been unsealed, then unseal it.
statusFile=`mktemp`
${VAULT} status >${statusFile} 2>&1
if [[ $? -eq 2 && "`isSealed ${statusFile}`" == "sealed" ]]; then
    echo Vault is sealed
    token=`unSeal`
    echo ${token}
fi
rm ${statusFile}

# check the status of vault. if it hasn't been unsealed, then we broke it :)
statusFile=`mktemp`
${VAULT} status >${statusFile} 2>&1
if [[ $? -eq 0 && "`isSealed ${statusFile}`" == "unsealed" ]]; then
    echo Vault is unsealed
    exit 0
fi
rm ${statusFile}

exit 1
EOF
chmod +x /tmp/vault-prepare
sudo cp /tmp/vault-prepare /usr/local/bin
sudo chown vault /usr/local/bin/vault-prepare

# clean up
sudo apt-get clean
sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
