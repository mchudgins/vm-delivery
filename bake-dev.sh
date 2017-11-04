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

source helpers/bash_functions

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

# is this a 'dirty' git repo?
commit=`gitCommitHash`

# retrieve the list of ami's owned by this account
IMAGES=`aws --region ${REGION} ec2 describe-images --owners self`

image_count=`echo ${IMAGES} | jq '.[] | length'`
for i in `seq 1 ${image_count}`; do
  var=`expr $i - 1`
  name=`echo ${IMAGES} | jq .Images[$var].Name | sed -e s/\"//g`
  if [[ ${name} == "${AMI_NAME}" ]]; then
    newAmi=`echo ${IMAGES} | jq .Images[$var].ImageId | sed -e s/\"//g`
    snapShotID=`echo ${IMAGES} | jq .Images[$var].BlockDeviceMappings[0].Ebs.SnapshotId | sed -e s/\"//g`
    echo Tagging AMI ${newAmi} with tag ParentAMI=${AMI}
    aws --region ${REGION} ec2 create-tags --resources ${newAmi} --tags Key=ParentAMI,Value=${AMI} \
        Key=ImageStream,Value=${IMAGE_STREAM} \
        Key="git.commit",Value="${commit}" \
        Key="git.origin",Value="$(gitOriginURL)"
    aws --region ${REGION} ec2 create-tags --resources ${snapShotID} --tags Key=Name,Value=${AMI_NAME} \
        Key=ImageStream,Value=${IMAGE_STREAM}
    exit 0
  fi
done

echo "Unable to tag newly created AMI"
exit 1