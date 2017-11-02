#! /bin/bash

VAULT_ARTIFACT="s3://dstcorp/artifacts/vault-0.8.3.zip"

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

# create a non-privileged vault user
sudo adduser --system --home /var/lib/vault --gecos 'vault,,,' --disabled-password vault

# install & configure VAULT as a single (non-HA) instance using s3 as the backing storage
aws s3 cp ${VAULT_ARTIFACT} /tmp/vault.zip \
    && unzip /tmp/vault.zip \
    && sudo mv vault /usr/local/bin \
    && sudo mkdir -p /usr/local/etc/vault \
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
ExecStart=/usr/local/bin/vault server -config /usr/local/etc/vault/config.hcl
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
EOF
sudo mv /tmp/vault.service /etc/systemd/system
sudo systemctl daemon-reload

# use rc.local to launch vault
sudo systemctl enable rc-local.service

# create the rc.local start script
cat <<"EOF" >/tmp/rc.local
#! /bin/bash
VAULT_CONFIG=/usr/local/etc/vault/config.hcl
hostname `hostname -s`.ec2.internal

if [[ ! -f ${VAULT_CONFIG}} ]]; then
    REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[abcdefghijk]$//'`

    # create the initial config for the seed instance of vault
    # (normally we should use spring cloud config server for this,
    # but it won't be running yet!)
cat <<EOF_CFG >/tmp/config.hcl
storage "s3" {
  bucket = "io.dstcorp.vault.${REGION}"
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

    sudo cp /tmp/config.hcl ${VAULT_CONFIG}

    aws --region ${REGION} s3 cp s3://io.dstcorp.vault.${REGION}/cert.pem /usr/local/etc/vault/cert.pem
    aws --region ${REGION} s3 cp s3://io.dstcorp.vault.${REGION}/key.pem /usr/local/etc/vault/key.pem
    chmod og-rw /usr/local/etc/vault/key.pem
    chmod u-w /usr/local/etc/vault/key.pem
    chown -R vault /usr/local/etc/vault
fi

#sudo -u vault /usr/local/bin/vault server -config=${VAULT_CONFIG} &
systemctl start vault
EOF
sudo cp /tmp/rc.local /etc/rc.local
sudo chmod +x /etc/rc.local

# clean up
sudo apt-get clean
sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
