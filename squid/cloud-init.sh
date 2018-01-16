#! /bin/bash

ARTIFACT_VERSION=3.5.27
SQUID_ARCHIVE=http://www.squid-cache.org/Versions/v3/3.5/squid-${ARTIFACT_VERSION}.tar.gz

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

sudo apt-get build-dep -yq squid
sudo apt-get install -yq --no-install-recommends libssl-dev

# create a non-privileged user
sudo adduser --system --home /var/lib/squid --gecos 'Squid Proxy,,,' --disabled-password squid


# install & build Squid
echo 'Starting Squid download & install'
wget ${SQUID_ARCHIVE} \
    && tar xvfz squid*.tar.gz \
    && cd $(basename squid*.tar.gz .tar.gz) \
    && ./configure --prefix=/usr --exec-prefix=/usr --libexecdir=/usr/lib64/squid --sysconfdir=/etc/squid --sharedstatedir=/var/lib --localstatedir=/var --libdir=/usr/lib64 --datadir=/usr/share/squid --with-logdir=/var/log/squid --with-pidfile=/var/run/squid.pid --with-default-user=squid --disable-dependency-tracking --enable-linux-netfilter --with-openssl --without-nettle \
    && make \
    && sudo make install \
    && cd \
    && rm -rf $(basename squid*.tar.gz .tar.gz) \
    && sudo apt-get remove autoconf build-essential gcc libssl-dev \
    && sudo apt-get autoremove \
    && sudo chown squid /var/lib/squid \
    && sudo mkdir /var/log/squid \
    && sudo chown squid /var/log/squid /var/cache/squid \
    && sudo chown -R squid /etc/squid \
    && sudo chmod 640 /etc/squid/squid.conf

# set up squid required, but not used, x509 self-signed cert
sudo mkdir /etc/squid/ssl
cd /etc/squid/ssl
sudo openssl genrsa -out squid.key 2048
sudo openssl req -new -key squid.key -out squid.csr -subj "/C=XX/ST=XX/L=squid/O=squid/CN=squid"
sudo openssl x509 -req -days 3650 -in squid.csr -signkey squid.key -out squid.crt
sudo cat squid.key squid.crt | sudo tee squid.pem
sudo chown -R squid /etc/squid

# set up the systemd service file for the service
cat <<"EOF" >/tmp/service
[Unit]
Description=Squid Proxy service
Wants=basic.target
After=basic.target network.target

[Service]
WorkingDirectory=/var/lib/squid
User=squid
Group=nogroup
ExecStart=/usr/sbin/squid
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/service /etc/systemd/system/squid.service
sudo systemctl daemon-reload
sudo systemctl enable squid

# route requests for port 80 to listener on port 8888
# note: need to save iptables across reboots via ifconfig up/down
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
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
