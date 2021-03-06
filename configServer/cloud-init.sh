#! /bin/bash

ARTIFACT=configserver-0.0.4-SNAPSHOT.jar

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
  apt-transport-https openjdk-8-jre-headless

# create a non-privileged user
sudo adduser --system --home /var/lib/config-server --gecos 'Spring Cloud Config Server,,,' --disabled-password config-server

# install & configure the Config Server
echo 'Starting prometheus installation'
aws s3 cp s3://dstcorp/artifacts/${ARTIFACT} /tmp/ \
    && sudo cp /tmp/${ARTIFACT} /usr/local/bin \
    && sudo mkdir -p /var/lib/config-server/target/config \
    && sudo chown -R config-server.nogroup /var/lib/config-server \
    && sudo mkdir -p /usr/local/etc/config-server \
    && sudo chown -R config-server.nogroup /usr/local/etc/config-server \
    && sudo chown root.root /usr/local/bin/*

# install & configure the jmx-exporter jar
echo 'Starting jmx-exporter installation'
sudo curl -sL https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/0.2.0/jmx_prometheus_javaagent-0.2.0.jar \
    -o /usr/local/bin/jmx_prometheus_javaagent-0.2.0.jar \
    && sudo chown root.root /usr/local/bin/*


# set up the systemd service file for the service
cat <<"EOF" >/tmp/service
[Unit]
Description=Spring Cloud Config service
Wants=basic.target
After=basic.target network.target

[Service]
WorkingDirectory=/var/lib/config-server
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
#
# this script launches the Spring Cloud Config Server
#

if [[ -f /etc/default/config-server ]]; then
    . /etc/default/config-server
fi

# the config server expects a subdir in the working dir called target/config
# to work in, so we need to create it if not present
if [[ ! -d target/config ]]; then
	mkdir -p target/config
fi

# the config server needs a java keystore which contains its x509 cert & key
if [[ ! -f /usr/local/etc/config-server/keystore.p12 ]]; then
    echo "Creating java keystore for config server"

    # generate 32 random alpha-numeric characters as a key for the keystore
    # and save it in /usr/local/etc/config-server/jks.key
    export JKS_KEY=`tr -dc _A-Z-a-z-0-9 </dev/urandom 2>/dev/null | head -c${1:-32}`
    echo ${JKS_KEY} >/usr/local/etc/config-server/jks.key
    chmod go-rw /usr/local/etc/config-server/jks.key

    # assemble the cert & key before constructing the jks

    # download a certificate & key for the service
    aws s3 cp s3://dstcorp/certificates/config.dst.cloud.pem /usr/local/etc/config-server
    if [[ $? -ne 0 ]]; then
        echo "Unable to download pem file (s3://dstcorp/certificates/config.dst.cloud.pem)"
        exit 1
    fi

    # fetch the key
    export x509key="$(/usr/local/bin/vault-get-cert config.dst.cloud)"
    if [[ $? -ne 0 ]]; then
        echo "Unable to obtain private key from vault"
        exit 2
    fi

    # TODO: pkcs12 is 'supposed' to read the concatenated pem file from stdin, but doesn't.
    # so we're creating a temporary file with the key in it (ugh).
    tmpfile=`mktemp`
    printenv x509key | cat /usr/local/etc/config-server/config.dst.cloud.pem - >${tmpfile}

    # create the keystore
    openssl pkcs12 -export -in ${tmpfile} -out /usr/local/etc/config-server/keystore.p12 \
        -name config-server -passout env:JKS_KEY

    rm ${tmpfile}
    chmod go-rw /usr/local/etc/config-server/keystore.p12

    echo "keystore created."
fi

JKS_KEY=`cat /usr/local/etc/config-server/jks.key`

echo /usr/bin/java ${APPFLAGS} \
    -Dserver.port=8443 \
    -Dserver.ssl.key-store=file:///usr/local/etc/config-server/keystore.p12 \
    -Dserver.ssl.key-store-password='<redacted>' \
    -Dserver.ssl.keyStoreType=PKCS12 \
    -Dserver.ssl.keyAlias=config-server \
    -Dspring.cloud.config.server.git.uri=${GIT_REPO_URL} \
	-Dspring.cloud.config.server.git.username=${GIT_REPO_UID} \
	-Dspring.cloud.config.server.git.password='<redacted>' \
	-javaagent:/usr/local/bin/jmx_prometheus_javaagent-0.2.0.jar=9110:/usr/local/etc/config-server/jmx-exporter.yaml \
	-jar ${APPJAR}
exec /usr/bin/java ${APPFLAGS} \
    -Dserver.port=8443 \
    -Dserver.ssl.key-store=file:///usr/local/etc/config-server/keystore.p12 \
    -Dserver.ssl.key-store-password=${JKS_KEY} \
    -Dserver.ssl.keyStoreType=PKCS12 \
    -Dserver.ssl.keyAlias=config-server \
	-Dspring.cloud.config.server.git.uri=${GIT_REPO_URL} \
	-Dspring.cloud.config.server.git.username=${GIT_REPO_UID} \
	-Dspring.cloud.config.server.git.password=${GIT_REPO_PWORD} \
	-javaagent:/usr/local/bin/jmx_prometheus_javaagent-0.2.0.jar=9110:/usr/local/etc/config-server/jmx-exporter.yaml \
	-jar ${APPJAR}
EOF
chmod +x /tmp/config-server-start
sudo cp /tmp/config-server-start /usr/local/bin

# set up default env in /etc/default/config-server
echo 'GIT_REPO_URL=https://github.com/mchudgins/config-props.git' >/tmp/config-server
echo 'APPFLAGS=-Djava.security.egd=file:/dev/./urandom' >>/tmp/config-server
echo "APPJAR=/usr/local/bin/${ARTIFACT}" >>/tmp/config-server
sudo cp /tmp/config-server /etc/default

# set up the trivial config for the jmx-exporter
cat <<EOF >/tmp/jmx-exporter.yaml
ssl: false
EOF
sudo -u config-server cp /tmp/jmx-exporter.yaml /usr/local/etc/config-server

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
