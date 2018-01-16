#
# Makefile for Amazon AMI's
#

TARGETS := $(shell bin/generateTargets)

ROOT_AMI := "ami-cd0f5cb6"

all: $(TARGETS)
	@echo $(TARGETS)

ubuntu.ami: aws-bake.json ubuntu/cloud-init.sh
	bin/bake --parent ami-534bc129 --image-stream ubuntu --artifact-version 17.10 \
		--description 'base image from Ubuntu 17.10' ubuntu/cloud-init.sh

configGen.ami: ubuntu.ami aws-bake.json configGen/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream configGen --description 'Cluster Config Generator based on Ubuntu' configGen/cloud-init.sh

configServer.ami: ubuntu.ami aws-bake.json configServer/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream configServer --artifact-version 0.0.4-SNAPSHOT \
		--description 'Spring Cloud Config Server based on Ubuntu' configServer/cloud-init.sh

dev.ami: ubuntu.ami aws-bake.json dev/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream dev --description 'Dev image based on Ubuntu' dev/cloud-init.sh

etcd.ami: ubuntu.ami aws-bake.json etcd/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream etcd --artifact-version 3.2.10 \
		--description 'etcd' etcd/cloud-init.sh

master.ami: ubuntu.ami aws-bake.json master/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream master --artifact-version 3.6.1 \
		--description 'Origin Master based on Ubuntu 17.10' master/cloud-init.sh

node.ami: ubuntu.ami aws-bake.json node/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream node --artifact-version 3.6.1 \
   		--description 'Origin Node based on Ubuntu 17.10' node/cloud-init.sh

prometheus.ami: ubuntu.ami aws-bake.json prometheus/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream prometheus --artifact-version 2.0.0 \
   		--description 'Prometheus based on Ubuntu 17.10' prometheus/cloud-init.sh

squid.ami: ubuntu.ami aws-bake.json squid/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream squid --artifact-version 3.5.27 \
   		--description 'Squid Proxy based on Ubuntu 17.10' squid/cloud-init.sh

vault.ami: ubuntu.ami aws-bake.json vault/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream vault --artifact-version 0.9.1 \
   		--description 'Hashicorp Vault based on Ubuntu 17.10' vault/cloud-init.sh

clean:
	rm *.ami
