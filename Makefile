#
# Makefile for Amazon AMI's
#

TARGETS := $(shell bin/generateTargets)

ROOT_AMI := "ami-cd0f5cb6"

all: $(TARGETS)
	@echo $(TARGETS)

base.ami: aws-bake.json ubuntu/cloud-init.sh
	bin/bake --parent ami-534bc129 --image-stream ubuntu --artifact-version 17.10 \
		--description 'base image from Ubuntu 17.10' ubuntu/cloud-init.sh

dev.ami: base.ami aws-bake.json dev/cloud-init.sh
	@echo Need to make a new dev image
	bin/bake --parent $(shell cat base.ami) --image-stream dev --description 'Dev image base on Ubuntu' dev/cloud-init.sh

origin-master.ami: ubuntu.ami aws-bake.json origin-master/ubuntu-dev-cloud-init.sh
	@echo Need to make a new dev image
