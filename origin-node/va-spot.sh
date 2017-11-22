#! /bin/bash

# check if a spot price was provided
if [[ -z "${SPOT_PRICE}" ]]; then
    BID_PRICE=0.0275
else
    BID_PRICE=${SPOT_PRICE}
fi

#
# default configuration
#

REGION=us-east-1
INSTANCE_TYPE=m4.large
KEY_NAME="kp201707"
SUBNET="subnet-08849b7f"
IMAGE_STREAM=node
CLUSTER_NAME=vpc0
NODE_NUM=0

#
# flags from command line may supersede defaults
#

while test $# -gt 0; do
    case "$1" in
        --node)
            shift
            NODE_NUM=$1
            ;;

        --cluster)
            shift
            CLUSTER_NAME=$1
            ;;

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

         *)
            break
            ;;
    esac
done

source ../helpers/bash_functions

# retrieve the list of ami's owned by this account
IMAGE_ID=$(mostRecentAMI ${IMAGE_STREAM})
echo "Launching ${IMAGE_ID}"

# create the cloud-init user data
USERDATA=$(cat <<-"_EOF_" | sed -e "s/REGION=xxx/REGION=${REGION}/" | base64 -w 0
#! /bin/bash
hostname `hostname -s`.ec2.internal

REGION=xxx
id >/tmp/id.uid
date > /tmp/cloud-final
echo CLUSTER_NAME=vpc0 >> /tmp/node-config
echo "OPENSHIFT_CONFIG=http://10.10.128.6/vpc0/default/vpc0/openshift/node/node-config.yaml" >> /tmp/node-config

cp /tmp/node-config /etc/default/openshift-node

systemctl start openshift-node
_EOF_
)

echo ${USERDATA} | base64 -d

# create the updated json launch config in a temp file
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "ImageId": "${IMAGE_ID}",
    "KeyName": "${KEY_NAME}",
    "UserData": "${USERDATA}",
    "InstanceType": "${INSTANCE_TYPE}",
    "IamInstanceProfile": {
        "Name": "ec2PackerInstanceRole"
    },
    "EbsOptimized": true,
    "Monitoring": {
        "Enabled": false
    },
    "NetworkInterfaces": [
      {
        "DeviceIndex": 0,
        "SubnetId": "${SUBNET}",
        "PrivateIpAddress": "10.10.128.$(expr 30 + ${NODE_NUM})",
        "Groups": [
            "sg-5ef8153a"
            ]
      }
    ]
}
EOF

cat ${FILE}

# launch the spot instance
instanceID=$(launchSpotInstance ${REGION} ${BID_PRICE} ${FILE})
if [[ $? != 0 ]]; then
    exit 1
fi

echo instanceID ${instanceID}

rm ${FILE}

#tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} \
    --tags Key=Name,Value=${IMAGE_STREAM}${NODE_NUM} Key=Cluster,Value=${CLUSTER_NAME} Key=Node,Value=ip-10-10-128-30


#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance available at ${ipaddr}

