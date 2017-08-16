#! /bin/bash
#
# This script launches the packer builder to create
# a 'ubuntu-dev' development virtual machine image.
#
TODAY=`date +%Y%m%d%H%M`
AMI='ami-cd0f5cb6'
AMI_NAME="dev-${TODAY}"
AMI_DESCRIPTION="Development based on Ubuntu 16.04 LTS"
INSTANCE_TYPE="t2.medium"
REGION="us-east-1"
SUBNET_ID="subnet-08849b7f"
SECURITY_GROUP_ID="sg-5ef8153a"
VPC_ID="vpc-94f4ffff"
VM_NAME=ubuntu-dev-${TODAY}

packer build \
	-var "ami_name=${AMI_NAME}" \
	-var "ami_description=${AMI_DESCRIPTION}" \
	-var "instance_type=${INSTANCE_TYPE}" \
	-var "source_ami=${AMI}" \
	-var "region=${REGION}" \
	-var "subnet_id=${SUBNET_ID}" \
	-var "vpc_id=${VPC_ID}" \
	-var "security_group_id=${SECURITY_GROUP_ID}" \
	ubuntu-dev.json | tee ubuntu-dev-${TODAY}.log

#VBoxManage modifyvm Fedora-Cloud-Base-24-1.2 --nic2 intnet
#VBoxManage modifyvm Fedora-Cloud-Base-24-1.2 --intnet2 cloud-net-0
