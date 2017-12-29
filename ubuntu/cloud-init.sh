#! /bin/bash

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

#   set up bazel package repo
#echo "deb [arch=amd64] http://storage.googleapis.com/bazel-apt stable jdk1.8" | sudo tee /etc/apt/sources.list.d/bazel.list
#curl https://bazel.build/bazel-release.pub.gpg | sudo apt-key add -

#   update package info
sudo apt-get update -yq

# the grub package doesn't respect -y by itself, so we need a bunch of extra options,
# or the provisioner will get stuck at an interactive prompt asking about Grub configuration
# see http://askubuntu.com/questions/146921/how-do-i-apt-get-y-dist-upgrade-without-a-grub-config-prompt
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -yq
sudo apt-get install -yq --no-install-recommends \
  apt-transport-https awscli \
  bash-completion ca-certificates chrony curl e2fsprogs ethtool htop jq \
  linux-image-extra-virtual nano \
  net-tools tcpdump unzip

# stop unattended upgrades -- that's why we have baked images!
sudo apt-get remove -yq unattended-upgrades
sudo apt autoremove -yq

# change the journald options to have only one log file
# rather than one per user
sudo sh -c 'echo "SplitMode=none" >>/etc/systemd/journald.conf'

# DST Root CA
aws s3 cp s3://dstcorp/dst-root.crt /tmp
sudo cp /tmp/dst-root.crt /usr/local/share/ca-certificates
sudo update-ca-certificates

# configure NTP/CHRONY to use the AWS endpoint  169.254.169.123 (see https://aws.amazon.com/blogs/aws/keeping-time-with-amazon-time-sync-service/)
sudo sed -i -e 's/pool/#pool/g' /etc/chrony/chrony.conf
sudo bash -c '"(see https://aws.amazon.com/blogs/aws/keeping-time-with-amazon-time-sync-service/)" >>/etc/chrony/chrony.conf'
sudo bash -c 'echo "server 169.254.169.123 prefer iburst" >>/etc/chrony/chrony.conf'

# set up the prometheus metrics exporter for this vm
aws s3 cp s3://dstcorp/artifacts/node_exporter-0.15.1.linux-amd64.tar.gz /tmp/node-ex.tar.gz \
    && cd /tmp && tar xfz node-ex.tar.gz \
    && sudo cp /tmp/node_exporter-0.15.1.linux-amd64/node_exporter /usr/local/bin \
    && cd -

cat <<"EOF" >/tmp/node-exporter.service
[Unit]
Description=node-exporter
After=network.target auditd.service

[Service]
ExecStart=/usr/local/bin/node_exporter
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/node-exporter.service /etc/systemd/system/node-exporter.service
sudo systemctl daemon-reload
sudo systemctl enable node-exporter

# install the vault-get-cert app
aws s3 cp s3://dstcorp/artifacts/vault-get-cert /tmp
chmod +x /tmp/vault-get-cert
sudo cp /tmp/vault-get-cert /usr/local/bin

# install a cloud-watch-logs service
# (see:  https://github.com/advantageous/systemd-cloud-watch and
# https://github.com/saymedia/journald-cloudwatch-logs)

# create a non-privileged vault user
sudo adduser --system --home /var/lib/cloud-watch --gecos 'AWS Cloud Watch Agent,,,' --disabled-password cloud-watch
# need privilege to read the systemd journal
sudo adduser cloud-watch systemd-journal

cat <<"EOF" >/tmp/cloud-watch.service
[Unit]
Description=journald-cloudwatch-logs
Wants=basic.target
After=basic.target network.target

[Service]
User=cloud-watch
Group=nogroup
ExecStart=/usr/local/bin/journald-cloudwatch-agent /etc/journald-cloudwatch-logs.conf
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/cloud-watch.service /etc/systemd/system
sudo systemctl daemon-reload
sudo systemctl enable cloud-watch.service

aws s3 cp s3://dstcorp/artifacts/journald-cloud-watch /tmp/journald-cloudwatch-logs
chmod +x /tmp/journald-cloudwatch-logs
sudo cp /tmp/journald-cloudwatch-logs /usr/local/bin

cat <<"EOF" >/tmp/journald-cloudwatch-logs.conf
log_group = "syslog"
log_stream = "${env.LOG_STREAM_NAME}"
state_file = "/var/lib/cloud-watch/state"
EOF
sudo cp /tmp/journald-cloudwatch-logs.conf /etc

cat <<"EOF" >/tmp/journald-cloudwatch-agent
#! /usr/bin/env bash
INSTANCE_NAME=null
id=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
az=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .availabilityZone`
region=`echo $az | sed -e 's/[a-z]$//'`

# see if this instance has a Name tag. if so, use it in the name
nameTag=`aws --region ${region} ec2 describe-instances --filters Name=instance-id,Values=$id \
    | jq '.Reservations[0].Instances[0].Tags | from_entries.Name' | sed -e 's/"//g'`
if [[ -z "${nameTag}" || "${nameTag}" == "null" ]]; then
    export LOG_STREAM_NAME=${id}
else
    export LOG_STREAM_NAME="${nameTag}-`hostname`-${az}"
fi

exec /usr/local/bin/journald-cloudwatch-logs /etc/journald-cloudwatch-logs.conf
EOF
chmod +x /tmp/journald-cloudwatch-agent
sudo cp /tmp/journald-cloudwatch-agent /usr/local/bin

# clean up
sudo apt-get autoremove
#sudo apt-get clean
#sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
