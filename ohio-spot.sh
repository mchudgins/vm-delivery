#! /bin/bash

# check if a spot price was provided
if [[ -z "${SPOT_PRICE}" ]]; then
    BID_PRICE=0.0275
else
    BID_PRICE=${SPOT_PRICE}
fi

# function to find the subnet, based on a volume-id and a list of subnet descriptions
function findSubnetFromVolumeID {
    local az=$2
	len=`echo "$1" | jq '.Subnets | length'`
	for i in $(seq 1 ${len}); do
	    j=$i-1
        subnetAZ=`echo "$1" | jq ".Subnets[$j].AvailabilityZone"`
        if [[ ${subnetAZ} == ${az} ]]; then
            echo `echo "$1" | jq ".Subnets[$j].SubnetId"`
        fi
	done
}

#
# configuration
#

REGION=us-east-2
INSTANCE_TYPE=r4.xlarge
VOLUME=vol-0adf4fd9ab9eb296d
KEY_NAME="us-east-2a"
AZ=`aws --region ${REGION} ec2 describe-volumes --volume-ids ${VOLUME} | jq .Volumes[0].AvailabilityZone`
SUBNETS=`aws --region ${REGION} ec2 describe-subnets`
SUBNET=`findSubnetFromVolumeID "${SUBNETS}" ${AZ}`

if [[ ! /bin/true ]]; then
    echo SUBNET=${SUBNET}
    exit 0
fi

# retrieve the list of ami's owned by this account
IMAGES=`aws --region ${REGION} ec2 describe-images --owners self`
#IMAGES=`cat /tmp/images.json`

# now find the latest image matching dev-<date/time>
ORIGIN_DATE="0000-00-00T00:00:00.000Z"
MAX_DATE=${ORIGIN_DATE}
MAX_IMAGE_INDEX=-1

image_count=`echo ${IMAGES} | jq '.[] | length'`
for i in `seq 1 ${image_count}`; do
  var=`expr $i - 1`
  name=`echo ${IMAGES} | jq .Images[$var].Name`
  IFS='-' read -ra NAME <<< "${name//\"/}"
  if [[ ${#NAME[@]} -eq 2 ]]; then
    if [[ ${NAME[0]} == "dev" ]]; then
      IMAGE_DATE=`echo ${IMAGES} | jq .Images[$var].CreationDate`
      if [[ "${MAX_DATE}" < "${IMAGE_DATE}" ]]; then
        MAX_DATE=${IMAGE_DATE}
        MAX_IMAGE_INDEX=${var}
      fi
    fi
  fi
done
IMAGE_NAME=`echo ${IMAGES} | jq .Images[${MAX_IMAGE_INDEX}].Name`
IMAGE_ID=`echo ${IMAGES} | jq .Images[${MAX_IMAGE_INDEX}].ImageId`
echo "Launching ${IMAGE_NAME} (${IMAGE_ID})"

# create the cloud-init user data
USERDATA=$(cat <<-"_EOF_" | sed -e "s/VOLUME=xxx/VOLUME=${VOLUME}/" -e "s/REGION=xxx/REGION=${REGION}/" | base64 -w 0
#! /bin/bash
TARGET_USER=mchudgins
REGION=xxx
VOLUME=xxx
id >/tmp/${TARGET_USER}.uid
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
    "ImageId": ${IMAGE_ID},
    "KeyName": "${KEY_NAME}",
    "SecurityGroupIds": [
        "sg-0a7b8863",
        "sg-1e857176",
        "sg-51867239"
    ],
    "UserData": "${USERDATA}",
    "InstanceType": "${INSTANCE_TYPE}",
    "SubnetId": ${SUBNET},
    "IamInstanceProfile": {
        "Name": "full-ec2-s3-access"
    },
    "EbsOptimized": true,
    "Monitoring": {
        "Enabled": false
    }
}
EOF

cat ${FILE}

cmd="aws --region ${REGION} ec2 request-spot-instances --spot-price ${BID_PRICE} --instance-count 1 --type one-time --launch-specification file://${FILE}"
echo cmd = ${cmd}
rc=`${cmd}`
echo $rc >/tmp/ohio.json

requestID=`echo ${rc} | jq .SpotInstanceRequests[0].SpotInstanceRequestId | sed -e 's/"//g'`
if [[ -z "${requestID}" ]]; then
    echo "Unable to find Spot Request ID"
    exit 1
fi

rm ${FILE}

# wait up to 5 minutes for an instance & either tag it or exit with error
sleep 15
instanceID=`aws --region ${REGION} ec2 describe-spot-instance-requests --spot-instance-request ${requestID} \
    | jq .SpotInstanceRequests[0].InstanceId | sed -e 's/"//g'`
echo instanceID ${instanceID}

while [[ "${instanceID}" == "null" ]]
  do
  sleep 5
  instanceID=`aws --region ${REGION} ec2 describe-spot-instance-requests --spot-instance-request ${requestID} \
    | jq .SpotInstanceRequests[0].InstanceId | sed -e 's/"//g'`
  done
aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=Name,Value=mch-dev

#display the instance's IP ADDR
ipaddr=`aws --region us-east-2 ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance availabe at ${ipaddr}