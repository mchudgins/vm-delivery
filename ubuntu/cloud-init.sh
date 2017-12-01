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

# clean up
sudo apt-get autoremove
#sudo apt-get clean
#sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
