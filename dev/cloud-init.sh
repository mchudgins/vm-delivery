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

sudo apt-get install -yq --no-install-recommends \
  apt-transport-https build-essential gcc make \
  openjdk-8-jdk-headless python software-properties-common \
  silversearcher-ag

# install AWS CLI/SDK
#curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "/tmp/awscli-bundle.zip"
#cd /tmp
#unzip awscli-bundle.zip
#sudo ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws

# maven
curl -sL http://www-us.apache.org/dist/maven/maven-3/3.5.2/binaries/apache-maven-3.5.2-bin.tar.gz \
  -o /tmp/maven.tar.gz

cd /opt && sudo tar xvfz /tmp/maven.tar.gz && sudo ln -s apache-maven-* mvn

# docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
# bug with Ubuntu 17.01, see https://gist.github.com/levsthings/0a49bfe20b25eeadd61ff0e204f50088
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu zesty stable"

sudo apt-get update
sudo apt-get install -yq --no-install-recommends docker-ce

# stop unattended upgrades -- that's why we have baked images!
sudo apt-get remove -yq unattended-upgrades
sudo apt autoremove -yq

#sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
#sudo sh -c "echo 'deb https://apt.dockerproject.org/repo ubuntu-xenial main' > /etc/apt/sources.list.d/docker.list"
#sudo apt-get update
#sudo apt-get purge lxc-docker
#sudo apt-cache policy docker-engine
#sudo apt-get install -yq --no-install-recommends linux-image-extra-$(uname -r) linux-image-extra-virtual
#sudo apt-get install -yq --no-install-recommends docker-engine

sudo groupadd docker
sudo sed -i /etc/systemd/system/multi-user.target.wants/docker.service \
  --follow-symlinks \
  -e 's|^ExecStart=/usr/bin/dockerd|ExecStart=/usr/bin/dockerd --insecure-registry 172.30.0.0/16|g'
sudo systemctl enable docker

# go 1.8.3
curl -sL https://storage.googleapis.com/golang/go1.8.3.linux-amd64.tar.gz -o /tmp/go.tar.gz
cd /usr/local
sudo tar xvfz /tmp/go.tar.gz
sudo mv go go1.8.3
# go 1.9.2
curl -sL https://redirector.gvt1.com/edgedl/go/go1.9.2.linux-amd64.tar.gz -o /tmp/go.tar.gz
cd /usr/local
sudo tar xvfz /tmp/go.tar.gz
sudo mv go go1.9.2
sudo ln -s go1.9.2 go

# sudo access for dev's
sudo bash -c 'echo "# all members of the dev group can sudo anything" >/etc/sudoers.d/dev'
sudo bash -c 'echo "%dev ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/dev'

sudo addgroup dev

# DST Root CA
aws s3 cp s3://dstcorp/dst-root.crt /tmp
sudo cp /tmp/dst-root.crt /usr/local/share/ca-certificates
sudo update-ca-certificates

# clean up
sudo apt-get autoremove
sudo apt-get clean
sudo rm -r /var/lib/apt/lists/*
rm -rf /tmp/*

echo 'Disk Summary after Update'
df -H
