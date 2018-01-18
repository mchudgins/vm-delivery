#! /bin/bash

#
# this script sets up a squid proxy for outbound access from AWS
# See: https://aws.amazon.com/blogs/security/how-to-add-dns-filtering-to-your-nat-instance-with-squid/
#

ARTIFACT_VERSION=3.5.27
SQUID_ARCHIVE=http://www.squid-cache.org/Versions/v3/3.5/squid-${ARTIFACT_VERSION}.tar.gz

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

echo 'Initial Disk Summary'
df -H

echo 'Starting Package Installations'

sudo apt-get update -yq
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
    && sudo apt-get remove -yq autoconf build-essential gcc libssl-dev \
    && sudo apt-get autoremove -yq \
    && sudo chown squid /var/lib/squid \
    && sudo chown squid /var/log/squid /var/cache/squid \
    && sudo chmod 750 /var/log/squid /var/cache/squid \
    && sudo touch /etc/squid/squid.conf \
    && sudo chown -R squid /etc/squid \
    && sudo chmod 640 /etc/squid/squid.conf

cat | sudo tee /etc/squid/squid.conf <<EOF
visible_hostname squid

# Add this port to the config to eliminate spurious error messages.
# we won't permit access to it in the SecurityGroup definition, so it's ok
http_port 3128

#Handling HTTP requests
http_port 3129 intercept
acl allowed_http_sites dstdomain .amazonaws.com
acl allowed_http_sites dstdomain .google.com
#acl allowed_http_sites dstdomain [you can add other domains to permit]
http_access allow allowed_http_sites

#Handling HTTPS requests
https_port 3130 cert=/etc/squid/ssl/squid.pem ssl-bump intercept
acl SSL_port port 443
http_access allow SSL_port
acl allowed_https_sites ssl::server_name .amazonaws.com
#acl allowed_https_sites ssl::server_name [you can add other domains to permit]
acl step1 at_step SslBump1
acl step2 at_step SslBump2
acl step3 at_step SslBump3
ssl_bump peek step1 all
ssl_bump peek step2 allowed_https_sites
ssl_bump splice step3 allowed_https_sites
ssl_bump terminate step2 all

http_access deny all
EOF

# set up squid required, but not used, x509 self-signed cert
sudo mkdir /etc/squid/ssl
cd /etc/squid/ssl
sudo openssl genrsa -out squid.key 2048
sudo openssl req -new -key squid.key -out squid.csr -subj "/C=XX/ST=XX/L=squid/O=squid/CN=squid"
sudo openssl x509 -req -days 3650 -in squid.csr -signkey squid.key -out squid.crt
sudo cat squid.key squid.crt | sudo tee squid.pem
sudo chown -R squid /etc/squid

# set up the systemd service file for the service
cat | sudo tee /etc/systemd/system/squid.service <<"EOF"
[Unit]
Description=Squid Proxy service
Documentation=man:squid(8)
Wants=basic.target
After=basic.target network.target

[Service]
WorkingDirectory=/var/lib/squid
Type=forking
PIDFile=/var/run/squid.pid
#ExecStartPre=/usr/sbin/squid --foreground -z
ExecStart=/usr/sbin/squid -sYC
ExecReload=/bin/kill -HUP $MAINPID
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable squid

#
# setup a cron job to look for configuration changes that should be applied to squid.conf
#

# first, create the script launched by cron
cat | sudo tee /usr/local/bin/squid-cfg-monitor <<"EOF"
#! /usr/bin/env bash
#
# /usr/local/bin/squid-cfg-monitor
#
# this script checks with the config server for the current version of
# /etc/squid/squid.conf.  if changes are found, the new config is installed and squid reloaded.
#

if [[ -s /etc/default/squid-cfg-monitor ]]; then
    . /etc/default/squid-cfg-monitor
fi

# if we don't know the cluster's name, we can't get the config.
# so squid can just keep running with it's original config.
if [[ -z "${CLUSTER_NAME}" ]]; then
    exit 0
fi

curl -s https://config.dst.cloud/${CLUSTER_NAME}/default/master/${CLUSTER_NAME}/squid/squid.conf >/tmp/squid.conf

if [[ ! -s /tmp/squid.conf ]]; then
    # no config found
    exit 0
fi

diff /etc/squid/squid.conf /tmp/squid.conf
if [[ $? -ne 0 ]]; then
    logger -t squid-cfg-monitor "Changes detected in squid configuration."
    cp /tmp/squid.conf /etc/squid/squid.conf
    chown squid /etc/squid/squid.conf
    chmod 640 /etc/squid/squid.conf
    systemctl reload squid

fi

EOF
sudo chmod +x /usr/local/bin/squid-cfg-monitor

# second, register the shell script as a cron job
cat | sudo tee /etc/cron.d/squid-cfg-monitor <<EOF
#
# cron.d/squid-cfg-monitor
#
# updates /etc/squid/squid.conf with changes from the config server
#
*/5 * * * * root /usr/local/bin/squid-cfg-monitor
EOF

# route requests for port 80 to listener on port 8888
# note: need to save iptables across reboots via ifconfig up/down
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3129
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 3130
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
