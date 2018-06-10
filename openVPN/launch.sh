#! /bin/bash

#
# default configuration
#

REGION=us-east-1
INSTANCE_TYPE=t2.nano
KEY_NAME="kp201707"
IMAGE_STREAM=openVPN
SUBNET_NAME=DST-mgmt-public
CLUSTER_NAME=dev
HOST_NAME=vpn.dstcorp.io

#
# flags from command line may supersede defaults
#

while test $# -gt 0; do
    case "$1" in
        --cluster)
            shift
            CLUSTER_NAME=$1
            ;;

        -h|--help)
            echo `basename $0` '--region (us-east-1|us-west-2)'
            ;;

        --hostname)
            shift
            HOST_NAME=$1
            ;;

        --image-stream)
            shift
            IMAGE_STREAM=$1
            ;;

        --instance-type)
            shift
            INSTANCE_TYPE=$1
            ;;

        --key-name)
            shift
            KEY_NAME=$1
            ;;

        --region)
            shift
            REGION=$1
            ;;

        --spot-price)
            shift
            SPOT_PRICE=$1
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

source ../helpers/bash_functions

# retrieve the list of ami's owned by this account
IMAGE_ID=$(mostRecentAMI ${IMAGE_STREAM})
echo "Launching ${IMAGE_ID}"

# compute the subnet id from the subnet name
AWSDATA=`aws ec2 describe-subnets --filters Name=tag:Name,Values=${SUBNET_NAME}`
SUBNET=`echo ${AWSDATA} | jq .Subnets[0].SubnetId | sed -s 's/"//g'`
VPC=`echo ${AWSDATA} | jq .Subnets[0].VpcId | sed -s 's/"//g'`
CIDR=`echo ${AWSDATA} | jq .Subnets[0].CidrBlock | sed -e 's^.0/24^^' -e 's/"//g'`
NODE_IP="${CIDR}.12"
echo SUBNET=${SUBNET} VPC=${VPC}
if [[ -z "${SUBNET}" || "${SUBNET}" == "null" ]]; then
    echo "Unable to find the private subnet (${SUBNET_NAME}) within the cluster"
    exit 1
fi

# find the security group(s)
    # first we need to find the name of the vpc
vpcinfo=$(aws --region ${REGION} ec2 describe-vpcs --filters Name=vpc-id,Values=${VPC})
vpcName=`echo ${vpcinfo} | jq '.Vpcs[0].Tags | from_entries.Name' | sed -e 's/"//g'`

if [[ -z "${vpcName}" ]]; then
    echo "Unable to find the vpc Name tag within vpc ${VPC}"
    exit 2
fi

    # then we can find the security group as <vpc-name>-vault

CONFIG_SECURITY_GROUP=`aws --region ${REGION} ec2 describe-security-groups \
    --filters Name=group-name,Values=default Name=vpc-id,Values=${VPC} | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`
NODE_EXPORTER_SECURITY_GROUP=`aws --region ${REGION} ec2 describe-security-groups \
    --filters Name=group-name,Values=${vpcName}-node-exporter | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`
OPENVPN_SECURITY_GROUP=`aws --region ${REGION} ec2 describe-security-groups \
    --filters Name=group-name,Values=${vpcName}-haproxy | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`


# create the cloud-init user data
USERDATA=$(cat <<-"_EOF_" | sed -e "s/CLUSTER_NAME=xxx/CLUSTER_NAME=${CLUSTER_NAME}/" | base64 -w 0
#cloud-config
runcmd:
    - iptables-restore < /etc/iptables.conf
_EOF_
)

echo ${USERDATA} | base64 -d

# create the updated json launch config in a temp file
EBS_OPTIMIZED=`isEBSOptimizable ${INSTANCE_TYPE}`
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "ImageId": "${IMAGE_ID}",
    "KeyName": "${KEY_NAME}",
    "UserData": "${USERDATA}",
    "InstanceType": "${INSTANCE_TYPE}",
    "InstanceInitiatedShutdownBehavior": "terminate",
    "EbsOptimized": ${EBS_OPTIMIZED},
    "Monitoring": {
        "Enabled": false
    },
    "IamInstanceProfile": {
        "Name": "ec2PackerInstanceRole"
    },
    "NetworkInterfaces": [
      {
        "AssociatePublicIpAddress": true,
        "DeviceIndex": 0,
        "SubnetId": "${SUBNET}",
        "PrivateIpAddress": "${NODE_IP}",
        "Groups": [
            "${CONFIG_SECURITY_GROUP}", "${NODE_EXPORTER_SECURITY_GROUP}", "${OPENVPN_SECURITY_GROUP}"
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
        echo "Launching an on-demand instance"
        USERDATAFILE=`mktemp`
        echo ${USERDATA} | base64 -d >${USERDATAFILE}
        instanceID=$(launchInstance ${REGION} ${FILE} ${USERDATAFILE})
        if [[ $? -ne 0 ]]; then
            echo "Error occurred; exiting."
            exit 1
        fi
        rm ${USERDATAFILE}
        ;;

    *)
        echo "Launching a spot instance"
        instanceID=$(launchSpotInstance ${REGION} ${BID_PRICE} ${FILE})
        if [[ $? != 0 ]]; then
            exit 1
        fi
        ;;
esac

echo instanceID ${instanceID}
echo "sleep 60 seconds to let things bake..."
sleep 60
rm ${FILE}

#tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=Name,Value="${HOST_NAME}"

#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance available at ${ipaddr}

# update the DNS entry for this new instance
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "Comment": "Update record to reflect public IP address of instance ${instanceID}",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "*.${HOST_NAME}.",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": ${ipaddr}
                    }
                ]
            }
        },
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${HOST_NAME}.",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": ${ipaddr}
                    }
                ]
            }
        }
    ]
}
EOF

ZONEID=`aws route53 list-hosted-zones | jq '.[][] | select(.Name=="dstcorp.io.") | .Id' | sed  -s 's/"//g' | sed -s 's|/hostedzone/||g'`
aws route53 change-resource-record-sets --hosted-zone-id ${ZONEID} --change-batch file://${FILE}

rm ${FILE}
