#! /bin/bash

ARTIFACT=configserver-0.0.2-SNAPSHOT.jar

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

# TODO: Upgrade to Java 9
# Getting a spring config loading issue with Java 9, reverted to Java 8
#
sudo apt-get install -yq --no-install-recommends \
  apt-transport-https build-essential openjdk-8-jre-headless

# create a non-privileged user
sudo adduser --system --home /var/lib/config-server --gecos 'Spring Cloud Config Server,,,' --disabled-password config-server

# install & configure the Config Server
echo 'Starting prometheus installation'
aws s3 cp s3://dstcorp/artifacts/${ARTIFACT} /tmp/ \
    && sudo cp /tmp/${ARTIFACT} /usr/local/bin \
    && sudo chown root.root /usr/local/bin/*

# set up the systemd service file for the service
cat <<"EOF" >/tmp/service
[Unit]
Description=Spring Cloud Config service
Wants=basic.target
After=basic.target network.target

[Service]
EnvironmentFile=/etc/default/config-server
User=config-server
Group=nogroup
ExecStart=/usr/local/bin/config-server-start
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/service /etc/systemd/system/config-server.service
sudo systemctl daemon-reload
sudo systemctl enable config-server

# set up the service start script
cat <<"EOF" >/tmp/config-server-start
#! /usr/bin/env bash

if [[ -f /etc/default/config-server ]]; then
    . /etc/default/config-server
fi

# download a certificate & key for the service
/usr/local/bin/vault-get-cert config.dst.cloud > /tmp/key.pem

exec /usr/bin/java ${APPFLAGS} -Dspring.cloud.config.server.git.uri=${GIT_REPO_URL} -jar ${APPJAR}
EOF
chmod +x /tmp/config-server-start
sudo cp /tmp/config-server-start /usr/local/bin

# set up default env in /etc/default/config-server
echo 'GIT_REPO_URL=https://github.com/mchudgins/config-props.git' >/tmp/config-server
echo 'APPFLAGS=-Djava.security.egd=file:/dev/./urandom' >>/tmp/config-server
echo "APPJAR=/usr/local/bin/${ARTIFACT}" >>/tmp/config-server
sudo cp /tmp/config-server /etc/default

# route requests for port 80 to listener on port 8888
# note: need to save iptables across reboots via ifconfig up/down
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8888
sudo iptables-save >/tmp/iptables.conf
sudo cp /tmp/iptables.conf /etc
cat <<"EOF" >/tmp/iptables
#! /usr/bin/env bash
iptables-restore < /etc/iptables.conf
EOF
chmod +x /tmp/iptables
sudo cp /tmp/iptables /etc/network/if-up.d/iptables

echo 'Disk Summary after Update'
df -H
