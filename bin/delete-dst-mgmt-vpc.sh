#!/usr/bin/env bash
#
# this script deletes the DST management VPC in the current account
#

HZ=Z2YR9UHTJ6SHRF


# exit immediately on an error
set -e

# assume we're running in an aws linux instance and need to install 'jq'
sudo yum install -y jq

REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/[a-z]$//'`

vpcid=`aws --region ${REGION} cloudformation describe-stacks --stack-name dst-mgmt-vpc | jq -r '.Stacks[0].Outputs[] | select(.ExportName=="DST-mgmt-vpcid").OutputValue'`

# delete the hosted zone association
aws --region ${REGION} route53 disassociate-vpc-from-hosted-zone --hosted-zone-id ${HZ} --vpc VPCRegion=${REGION},VPCId=${vpcid}

# delete the endpoint before the stack
endpoint=`aws --region ${REGION} ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${vpcid} Name=service-name,Values=com.amazonaws.${REGION}.ec2 | jq -r '.VpcEndpoints[0].VpcEndpointId'`
echo aws --region ${REGION} ec2 delete-vpc-endpoints --vpc-endpoint-ids ${endpoint}
aws --region ${REGION} ec2 delete-vpc-endpoints --vpc-endpoint-ids ${endpoint}

# delete the stack
echo aws --region ${REGION} cloudformation delete-stack --stack-name dst-mgmt-vpc
aws --region ${REGION} cloudformation delete-stack --stack-name dst-mgmt-vpc

sleep 120
sudo shutdown -h now
