#
# Makefile for Amazon AMI's
#

TARGETS := $(shell bin/generateTargets)

all: $(TARGETS)
	@echo $(TARGETS)

ubuntu.ami: ubuntu/ubuntu-dev.json ubuntu/ubuntu-cloud-init.sh
	@echo Need to make a new $@ image

dev.ami: ubuntu.ami dev/ubuntu-dev.json dev/ubuntu-dev-cloud-init.sh
	@echo Need to make a new dev image

origin-master.ami: ubuntu.ami dev/ubuntu-dev.json dev/ubuntu-dev-cloud-init.sh
	@echo Need to make a new dev image
