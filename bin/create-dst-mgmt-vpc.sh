#!/usr/bin/env bash
#
# this script creates the DST management VPC in the current account
#

HZ=Z2YR9UHTJ6SHRF

# assume we're running in an aws linux instance and need to install 'jq'
sudo yum install -y jq

REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/[a-z]$//'`

aws --region ${REGION} cloudformation create-stack --stack-name dst-mgmt-vpc --template-url https://s3.amazonaws.com/dstcorp/cf-templates/vpc-mgmt.template.yaml \
   --on-failure DELETE \
   --parameters ParameterKey=pVPCCIDR,ParameterValue=10.255.0.0/16 \
       ParameterKey=pPublicCIDR,ParameterValue=10.255.0.0/24 \
       ParameterKey=pPrivateCIDR,ParameterValue=10.255.255.0/24 \
       ParameterKey=pVPCTenancy,ParameterValue=default \
       ParameterKey=pEnvironment,ParameterValue=alpha \
       ParameterKey=pAZ,ParameterValue=us-east-1e \
       ParameterKey=pOwner,ParameterValue='mchudgins@dstsystems.com' \
   --tags Key=Owner,Value='mchudgins@dstsystems.com'

#
# wait for the stack to be created
#
n=0
TIMEOUT=15
while [[ `aws --region ${REGION} cloudformation describe-stacks --stack-name dst-mgmt-vpc | jq -r .Stacks[0].StackStatus` != "CREATE_COMPLETE" ]]; do
    if [[ $n -ge ${TIMEOUT} ]]; then
        echo "Time expired waiting for stack completion."
        exit 1
    fi
    sleep 60
    n=$[$n+1]
done

# cloud formation does not yet support creating vpc interface endpoints, so create them here.

# compute the correct subnet
SUBNET_NAME="DST-mgmt-public"
subnets=`aws --region ${REGION} ec2 describe-subnets --filters Name=tag:Name,Values=${SUBNET_NAME}`
subnet=`echo ${subnets} | jq .Subnets[0].SubnetId | sed -e 's/"//g'`
if [[ -z "${subnet}" || "${subnet}" == "null" ]]; then
    echo "Unable to find subnet named ${SUBNET_NAME}"
    exit 1
fi
vpcid=`echo ${subnets} | jq .Subnets[0].VpcId | sed -e 's/"//g'`
SUBNET=${subnet}

aws --region ${REGION} ec2 create-vpc-endpoint --vpc-id ${vpcid} --service-name com.amazonaws.${REGION}.ec2 --private-dns-enabled --subnet-ids ${SUBNET} --vpc-endpoint-type Interface

# associate the vpc with the route53 hosted zone
aws --region ${REGION} route53 associate-vpc-with-hosted-zone --hosted-zone-id ${HZ} --vpc VPCRegion=${REGION},VPCId=${vpcid}



sleep 120
sudo shutdown -h now
