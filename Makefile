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

dev.ami: ubuntu.ami aws-bake.json dev/cloud-init.sh
	@echo Need to make a new dev image
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream dev --description 'Dev image base on Ubuntu' dev/cloud-init.sh

etcd.ami: ubuntu.ami aws-bake.json etcd/cloud-init.sh
	bin/bake --parent $(shell cat ubuntu.ami) --image-stream etcd --artifact-version 3.2.10 \
		--description 'etcd' etcd/cloud-init.sh

origin-master.ami: ubuntu.ami aws-bake.json origin-master/ubuntu-dev-cloud-init.sh
	@echo Need to make a new dev image

clean:
	rm *.ami
