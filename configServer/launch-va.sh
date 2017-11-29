#! /bin/bash

#
# default configuration
#

REGION=us-east-1
INSTANCE_TYPE=t2.nano
SPOT_PRICE=0.02
KEY_NAME="kp201707"
SUBNET="subnet-08849b7f"
IMAGE_STREAM=dev
CLUSTER_NAME=vpc0
NODE_IP="10.10.128.6"

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

        --image-stream)
            shift
            IMAGE_STREAM=$1
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

# create the cloud-init user data
#USERDATA=$(cat <<-_EOF_ | base64 -w 0
##! /usr/bin/env bash
#hostname ip-10-10-128-6.ec2.internal
#
#REGION=${REGION}
#
#echo "hello" >/tmp/cloud-init
#
#docker run -d -e GIT_REPO_URL=https://github.com/mchudgins/config-props.git -p 80:8888 \
#    mchudgins/configserver:0.0.2-SNAPSHOT
#_EOF_
#)
$(cat <<-_EOF_ >/tmp/userdata
#cloud-config
runcmd:
 - 'aws s3 cp s3://dstcorp/artifacts/node_exporter-0.15.1.linux-amd64.tar.gz ./node-ex.tar.gz
 && tar xfz node-ex.tar.gz
 && ./node_exporter-0.15.1.linux-amd64/node_exporter &'
 - docker run -d -e GIT_REPO_URL=https://github.com/mchudgins/config-props.git -p 80:8888 mchudgins/configserver:0.0.2-SNAPSHOT
_EOF_
)

#echo ${USERDATA} | base64 -d

# create the updated json launch config in a temp file
#    "EbsOptimized": true,
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "ImageId": "${IMAGE_ID}",
    "KeyName": "${KEY_NAME}",
    "UserData": "${USERDATA}",
    "InstanceType": "${INSTANCE_TYPE}",
    "InstanceInitiatedShutdownBehavior": "terminate",
    "IamInstanceProfile": {
        "Name": "ec2PackerInstanceRole"
    },
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

# launch an on demand instance
instanceID=$(launchInstance ${REGION} ${FILE} /tmp/userdata)

# launch the spot instance
#instanceID=$(launchSpotInstance ${REGION} ${SPOT_PRICE} ${FILE})

if [[ $? != 0 ]]; then
    exit 1
fi

echo instanceID ${instanceID}

rm ${FILE}

#tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=Name,Value="configServer"

#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance available at ${ipaddr}

# update the DNS entry for this new instance of vault-seed-${REGION}.dstcorp.io
upsertDNS "config-${REGION}.dstcorp.io." ${ipaddr} ${instanceID}
