#! /bin/bash

#
# configuration
#

REGION=us-east-1
INSTANCE_TYPE=t2.nano
KEY_NAME="kp201707"
SUBNET=""
SUBNET_NAME="o7t-alpha-mgmt"
IMAGE_STREAM="configGen"
PRIVATE_IP=10.250.254.250

source ../helpers/bash_functions

#
# flags from command line may supersede defaults
#

while test $# -gt 0; do
    case "$1" in
        -h|--help)
            echo `basename $0` '--region (us-east-1|us-west-2)'
            ;;

        --instance-type)
            shift
            INSTANCE_TYPE=$1
            ;;

        --key-name)
            shift
            KEY_NAME=$1
            ;;

        --private-ip)
            shift
            PRIVATE_IP=$1
            ;;

        --region)
            shift
            REGION=$1
            ;;

        --spot-price)
            shift
            SPOT_PRICE=$1
            ;;

        --subnet)
            shift
            SUBNET=$1
            ;;

        --subnet-name)
            shift
            SUBNET_NAME=$1
            ;;

         *)
            break
            ;;

    esac
    shift
done

# check if a spot price was provided
if [[ -z "${SPOT_PRICE}" ]]; then
    BID_PRICE=0.0275
else
    BID_PRICE=${SPOT_PRICE}
fi

# retrieve the list of ami's owned by this account
IMAGE_ID=$(mostRecentAMI ${IMAGE_STREAM})
echo "Launching ${IMAGE_ID}"

# find the subnet to run this image in, if SUBNET not provided
if [[ -z "${SUBNET}" ]]; then
    subnets=`aws --region ${REGION} ec2 describe-subnets --filters Name=tag:Name,Values=${SUBNET_NAME}`
    subnet=`echo ${subnets} | jq .Subnets[0].SubnetId | sed -e 's/"//g'`
    if [[ -z "${subnet}" || "${subnet}" == "null" ]]; then
        echo "Unable to find subnet named ${SUBNET_NAME}"
        exit 1
    fi
    vpcid=`echo ${subnets} | jq .Subnets[0].VpcId | sed -e 's/"//g'`
    SUBNET=${subnet}
fi

# find the security group(s)
    # first we need to find the name of the vpc
vpcinfo=$(aws --region ${REGION} ec2 describe-vpcs --filters Name=vpc-id,Values=${vpcid})
    # iterate over the tags for the "Name" tag
vpcName=`echo ${vpcinfo} | jq '.Vpcs[0].Tags | from_entries.Name' | sed -e 's/"//g'`

if [[ -z "${vpcName}" ]]; then
    echo "Unable to find the vpc Name tag within vpc ${vpcid}"
    exit 2
fi

securityGroupName=""

    # then we can find the security group as <vpc-name>-vault

VAULT_SECURITY_GROUP=`aws --region ${REGION} ec2 describe-security-groups \
    --filters Name=group-name,Values=${vpcName}-vault | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`
NODE_EXPORTER_SECURITY_GROUP=`aws --region ${REGION} ec2 describe-security-groups \
    --filters Name=group-name,Values=${vpcName}-prometheus-monitored-instance | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`

# create the cloud-init user data
USERDATA=$(cat <<-"_EOF_" | sed -e "s/REGION=xxx/REGION=${REGION}/" | base64 -w 0
#! /usr/bin/env bash

# set up some up some key inputs of the config generation
echo "S3CABUNDLE=s3://dstcorp/certificates/ucap-ca-bundle.pem" >>/etc/default/configGen
echo "CLUSTER=mch" >> /etc/default/configGen

# run the script in the /tmp directory where we have write permission
export HOME=/tmp

# run the script and shutdown iff it's successful; otherwise, leave it running for debug purposes
/usr/local/bin/configGen
if [[ $? -eq 0 ]]; then
    echo "configuration generated successfully."
    sudo shutdown -h +5
fi
_EOF_
)

echo ${USERDATA} | base64 -d

# create the updated json launch config in a temp file
FILE=`mktemp`
EBS_OPTIMIZED=`isEBSOptimizable ${INSTANCE_TYPE}`
cat <<EOF >${FILE}
{
    "ImageId": "${IMAGE_ID}",
    "KeyName": "${KEY_NAME}",
    "UserData": "${USERDATA}",
    "InstanceType": "${INSTANCE_TYPE}",
    "IamInstanceProfile": {
        "Name": "ec2VaultSeed"
    },
    "EbsOptimized": ${EBS_OPTIMIZED},
    "Monitoring": {
        "Enabled": false
    },
    "NetworkInterfaces": [
      {
        "AssociatePublicIpAddress": true,
        "DeviceIndex": 0,
        "SubnetId": "${SUBNET}",
        "PrivateIpAddress": "${PRIVATE_IP}",
        "Groups": [
            "${VAULT_SECURITY_GROUP}", "${NODE_EXPORTER_SECURITY_GROUP}"
            ]
      }
    ]
}
EOF

        cat ${FILE}

# launch the instance. if a t2.* type use an on-demand instance, otherwise make a spot request
IFS="." read -r -a el <<< "${INSTANCE_TYPE}"
case "${el[0]}" in
    t2)
        USERDATAFILE=`mktemp`
        echo ${USERDATA} | base64 -d >${USERDATAFILE}
        instanceID=$(launchInstance ${REGION} ${FILE} ${USERDATAFILE})
        rm ${USERDATAFILE}
        ;;

    *)
        instanceID=$(launchSpotInstance ${REGION} ${BID_PRICE} ${FILE})
        if [[ $? != 0 ]]; then
            exit 1
        fi
        ;;
esac

if [[ -z "${instanceID}" ]]; then
    echo "Unable to launch an instance"
    exit 1
fi

echo instanceID ${instanceID}

rm ${FILE}

#tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=Name,Value=${IMAGE_STREAM}

#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance available at ${ipaddr}
