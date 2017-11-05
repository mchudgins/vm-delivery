#! /bin/bash

# check if a spot price was provided
if [[ -z "${SPOT_PRICE}" ]]; then
    BID_PRICE=0.0275
else
    BID_PRICE=${SPOT_PRICE}
fi

# function to find the subnet, based on a volume-id and a list of subnet descriptions
function findSubnetFromVolumeID {
    echo \"subnet-6e8b8005\"
#    local az=$2
#	len=`echo "$1" | jq '.Subnets | length'`
#	for i in $(seq 1 ${len}); do
#	    j=$i-1
#       subnetAZ=`echo "$1" | jq ".Subnets[$j].AvailabilityZone"`
#        if [[ ${subnetAZ} == ${az} ]]; then
#            echo `echo "$1" | jq ".Subnets[$j].SubnetId"`
#        fi
#	done
}

#
# configuration
#

REGION=us-east-1
INSTANCE_TYPE=r4.xlarge
VOLUME=vol-a7205872
KEY_NAME="kp201707"
AZ=`aws --region ${REGION} ec2 describe-volumes --volume-ids ${VOLUME} | jq .Volumes[0].AvailabilityZone`
SUBNETS=`aws --region ${REGION} ec2 describe-subnets`
SUBNET=`findSubnetFromVolumeID "${SUBNETS}" ${AZ}`

if [[ ! /bin/true ]]; then
    echo SUBNET=${SUBNET}
    exit 0
fi

source ../helpers/bash_functions

IMAGE_ID=$(mostRecentAMI ${IMAGE_STREAM})
echo "Launching ${IMAGE_ID}"

# create the cloud-init user data
USERDATA=$(cat <<-"_EOF_" | sed -e "s/VOLUME=xxx/VOLUME=${VOLUME}/" -e "s/REGION=xxx/REGION=${REGION}/" | base64 -w 0
#! /bin/bash
TARGET_USER=mchudgins
REGION=xxx
VOLUME=xxx
hostname mch-dev.dstcorp.io
adduser --gecos 'Mike Hudgins,,,' --disabled-password ${TARGET_USER}
aws --region ${REGION} ec2 attach-volume --volume-id ${VOLUME} \
  --instance-id `curl -s http://169.254.169.254/latest/meta-data/instance-id` \
  --device /dev/xvdh
addgroup dev
adduser ${TARGET_USER} dev
ls /dev/xvdh
while [[ $? != 0 ]]
  do
  sleep 5
  ls /dev/xvdh
  done
mount /dev/xvdh /home/${TARGET_USER}
chown -R ${TARGET_USER}.${TARGET_USER} /home/${TARGET_USER}
if [[ -x /home/${TARGET_USER}/rc.local ]]; then
  /home/${TARGET_USER}/rc.local
fi
_EOF_
)

echo ${USERDATA} | base64 -d

# create the updated json launch config in a temp file
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "ImageId": "${IMAGE_ID}",
    "KeyName": "${KEY_NAME}",
    "SecurityGroupIds": [
        "sg-5ef8153a"
    ],
    "UserData": "${USERDATA}",
    "InstanceType": "${INSTANCE_TYPE}",
    "SubnetId": ${SUBNET},
    "IamInstanceProfile": {
        "Name": "ec2PackerInstanceRole"
    },
    "EbsOptimized": true,
    "Monitoring": {
        "Enabled": false
    }
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

# tag the instance
aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=Name,Value=mch-dev

#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance available at ${ipaddr}
