#! /bin/bash
#
# This script launches the packer builder to create
# a 'ubuntu-dev' development virtual machine image.
#
IMAGE_STREAM='dev'
TODAY=`date +%Y%m%d%H%M`
AMI='ami-cd0f5cb6'
AMI_NAME="${IMAGE_STREAM}-${TODAY}"
AMI_DESCRIPTION="Development based on Ubuntu 16.04 LTS"
IAM_INSTANCE_PROFILE="ec2PackerInstanceRole"
INSTANCE_TYPE="t2.medium"
REGION="us-east-1"
SUBNET_ID="subnet-08849b7f"
SECURITY_GROUP_ID="sg-5ef8153a"
VPC_ID="vpc-94f4ffff"
VM_NAME=ubuntu-dev-${TODAY}

source ../helpers/bash_functions

packer build \
    -var "spot_price=auto" \
    -var "spot_price_auto_product=Linux/UNIX" \
	-var "ami_name=${AMI_NAME}" \
	-var "ami_description=${AMI_DESCRIPTION}" \
	-var "iam_instance_profile=${IAM_INSTANCE_PROFILE}" \
	-var "instance_type=${INSTANCE_TYPE}" \
	-var "source_ami=${AMI}" \
	-var "region=${REGION}" \
	-var "subnet_id=${SUBNET_ID}" \
	-var "vpc_id=${VPC_ID}" \
	-var "security_group_id=${SECURITY_GROUP_ID}" \
	ubuntu-dev.json | tee ubuntu-dev-${TODAY}.log

#
# tag the newly created AMI with the parent's AMI ID
# (we can use this later for inventory management)
#

tagAMI ${AMI_NAME} ${IMAGE_STREAM} ${AMI}