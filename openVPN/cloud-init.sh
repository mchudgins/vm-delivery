#! /bin/bash

# hmmmm, need to set the hostname to something the AWS DNS server knows
sudo hostname `hostname -s`.ec2.internal

echo 'OS Release : ' `cat /etc/issue`
echo 'Kernel Info: ' `uname -a`

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
    openvpn easy-rsa

# set up the init of openvpn
cat | sudo tee /usr/local/bin/openvpn-init <<"EOF"
#! /usr/bin/env bash
#
# this script assumes:
#
#   1) that the vault service and the config service are online
#
#   2) that it is run as root
#

APPNAME=vpn.dstcorp.io
CERTNAME=star.dstcorp.io

if [[ -r /etc/default/openvpn ]]; then
    . /etc/default/openvpn
fi

# fetch the cert for '*.dstcorp.io'
curl -s https://config.dst.cloud/${APPNAME}/default/master/certificates/${CERTNAME}.pem >/etc/openvpn/server/cert.pem

# fetch the key for '*.dstcorp.io'
vault-get-cert ${CERTNAME} >/etc/openvpn/server/key.pem

# fetch the config file for the openvpn server
curl -s https://config.dst.cloud/${APPNAME}/default/master/openvpn/server.conf >/etc/openvpn/server/server.conf

exec /usr/sbin/openvpn --config /etc/openvpn/server/server.conf
EOF
sudo chmod +x /usr/local/bin/openvpn-init

# (over)write the service specification for openvpn
cat | sudo tee /lib/systemd/system/openvpn.service <<"EOF"
[Unit]
Description=OpenVPN service
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/openvpn-init
ExecReload=/bin/true
WorkingDirectory=/etc/openvpn

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable openvpn.service

# generate the Diffie Hellman parameters file.  takes a long time.
openssl dhparam -out /tmp/dh2048.pem 2048
sudo cp /tmp/dh2048.pem /etc/openvpn/server/dh2048.pem

# enable ip forwarding on reboot
echo net.ipv4.conf.ip_forward=1 | sudo tee -a /etc/sysctl.conf

# NAT 10.8.0.0/24 traffic to the remote subnet's
# (see https://arashmilani.com/post?id=53)
sudo iptables -A FORWARD -i tun+ -j ACCEPT
sudo iptables -A INPUT -i tun+ -j ACCEPT
sudo iptables -A FORWARD -i tun+ -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
sudo iptables -A OUTPUT -o tun+ -j ACCEPT

# clean up
sudo apt-get autoremove
#sudo apt-get clean
#sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
