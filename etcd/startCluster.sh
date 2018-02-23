#! /bin/bash

#
# default configuration
#

REGION=us-east-1
INSTANCE_TYPE=t2.nano
KEY_NAME="kp201707"
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

source ../helpers/bash_functions

# retrieve the list of ami's owned by this account
IMAGE_ID=$(mostRecentAMI ${IMAGE_STREAM})
echo "Launching ${IMAGE_ID}"

# compute the subnet id from the subnet name
AWSDATA=`aws ec2 describe-subnets --filters Name=tag:Name,Values=${CLUSTER_NAME}-private`
SUBNET=`echo ${AWSDATA} | jq .Subnets[0].SubnetId | sed -s 's/"//g'`
VPC=`echo ${AWSDATA} | jq .Subnets[0].VpcId | sed -s 's/"//g'`
CIDR=`echo ${AWSDATA} | jq .Subnets[0].CidrBlock | sed -e 's^.0/24^^' -e 's/"//g'`
echo SUBNET=${SUBNET} VPC=${VPC}
if [[ -z "${SUBNET}" || "${SUBNET}" == "null" ]]; then
    echo "Unable to find the private subnet (${CLUSTER_NAME}-private) within the ${CLUSTER_NAME} cluster"
    exit 1
fi

# find the security groups: <vpc-name>-etcd and <vpc-name>-prometheus-monitored-instance
    # first we need to find the name of the vpc
vpcinfo=$(aws --region ${REGION} ec2 describe-vpcs --filters Name=vpc-id,Values=${VPC})
    # iterate over the tags for the "Name" tag
tagCount=$(echo ${vpcinfo} | jq '.Vpcs[] | length')
for j in `seq 1 ${tagCount}`; do
    iter=`expr $j - 1`
    tagName=`echo ${vpcinfo} | jq .Vpcs[0].Tags[$iter].Key | sed -e 's/"//g'`
    if [[ ${tagName} == "Name" ]]; then
        vpcName=`echo ${vpcinfo} | jq .Vpcs[0].Tags[$iter].Value | sed -e 's/"//g'`
    fi
done

if [[ -z "${vpcName}" ]]; then
    echo "Unable to find the vpc Name tag within vpc ${VPC}"
    exit 2
fi

etcdSG=`aws ec2 describe-security-groups --filters Name=group-name,Values=${vpcName}-etcd | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`
promSG=`aws ec2 describe-security-groups --filters Name=group-name,Values=o7t-alpha-prometheus-monitored-instance | jq .SecurityGroups[0].GroupId | sed -e 's/"//g'`


#
# define 'launchInstance' to spin up a VM on AWS
# with the appropriate parameters
#

function launchEtcdInstance {

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
#hostname ip-`echo ${NODE_NAME}-${CLUSTER_NAME} | sed -e 's/\./-/g'`.dst.cloud
hostname ${NODE_NAME}-${CLUSTER_NAME}.dst.cloud

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
EBS_OPTIMIZED=`isEBSOptimizable ${INSTANCE_TYPE}`
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
    "EbsOptimized": ${EBS_OPTIMIZED},
    "Monitoring": {
        "Enabled": false
    },
    "NetworkInterfaces": [
      {
        "DeviceIndex": 0,
        "SubnetId": "${SUBNET}",
        "PrivateIpAddress": "${NODE_IP}",
        "Groups": [
            "${etcdSG}", "${promSG}"
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

rm ${FILE}

# tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} \
    --tags Key=Name,Value=${NODE_NAME} Key=Cluster,Value=${CLUSTER_NAME}

#display the instance's IP ADDR
#ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance ${instanceID}
}

CLUSTER_INIT="etcd0=https://${CIDR}.10:2380,etcd1=https://${CIDR}.11:2380,etcd2=https://${CIDR}.12:2380"
launchEtcdInstance 0 etcd "${CIDR}.10" ${CLUSTER_NAME} ${CLUSTER_INIT}
launchEtcdInstance 1 etcd "${CIDR}.11" ${CLUSTER_NAME} ${CLUSTER_INIT}
launchEtcdInstance 2 etcd "${CIDR}.12" ${CLUSTER_NAME} ${CLUSTER_INIT}
