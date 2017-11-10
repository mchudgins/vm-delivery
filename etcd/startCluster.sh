#! /bin/bash

#
# default configuration
#

REGION=us-east-1
INSTANCE_TYPE=m4.large
KEY_NAME="kp201707"
SUBNET="subnet-08849b7f"
IMAGE_STREAM=etcd
CLUSTER_NAME=vpc0
NODE_IP="10.10.128.10"

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

# check if a spot price was provided
if [[ -z "${SPOT_PRICE}" ]]; then
    BID_PRICE=0.0275
else
    BID_PRICE=${SPOT_PRICE}
fi

source ../helpers/bash_functions

# retrieve the list of ami's owned by this account
IMAGE_ID=$(mostRecentAMI ${IMAGE_STREAM})
echo "Launching ${IMAGE_ID}"

#
# define 'launchInstance' to spin up a VM on AWS
# with the appropriate parameters
#

function launchInstance {

INSTANCE_ID=$1
NODE_NAME=$2$1
NODE_IP=$3
CLUSTER_NAME=$4
CLUST_INIT=$5

ENV_FILE=/etc/default/etcd

# create the cloud-init user data
#USERDATA=$(cat <<-"_EOF_" | sed -e "s/REGION=xxx/REGION=${REGION}/" | base64 -w 0
USERDATA=$(cat <<-_EOF_ | base64 -w 0
#! /bin/bash
hostname ip-`echo ${NODE_IP} | sed -e 's/\./-/g'`.ec2.internal

id >/tmp/id.uid
date > /tmp/cloud-final
echo REGION=${REGION}              > ${ENV_FILE}
echo INSTANCE_ID=${INSTANCE_ID}   >> ${ENV_FILE}
echo NODE_NAME=${NODE_NAME}       >> ${ENV_FILE}
echo NODE_IP="${NODE_IP}"         >> ${ENV_FILE}
echo CLUSTER_NAME=${CLUSTER_NAME} >> ${ENV_FILE}
echo INITIAL_CLUSTER=${CLUST_INIT} >> ${ENV_FILE}
echo CLIENT_CA=s3://dstcorp/etcd/etcd-client-ca.pem >> ${ENV_FILE}

systemctl start etcd
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
        "PrivateIpAddress": "${NODE_IP}",
        "Groups": [
            "sg-5ef8153a"
            ]
      }
    ]
}
EOF

cat ${FILE}

instanceID=$(launchSpotInstance ${REGION} ${BID_PRICE} ${FILE})
if [[ $? != 0 ]]; then
    exit 1
fi

rm ${FILE}

# tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} \
    --tags Key=Name,Value=${NODE_NAME} Key=Cluster,Value=${CLUSTER_NAME}

#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance ${instanceID} available at ${ipaddr}
}

CLUSTER_INIT="etcd0=https://10.10.128.10:2380,etcd1=https://10.10.128.11:2380,etcd2=https://10.10.128.12:2380"
launchInstance 0 etcd "10.10.128.10" ${CLUSTER_NAME} ${CLUSTER_INIT}
launchInstance 1 etcd "10.10.128.11" ${CLUSTER_NAME} ${CLUSTER_INIT}
launchInstance 2 etcd "10.10.128.12" ${CLUSTER_NAME} ${CLUSTER_INIT}
