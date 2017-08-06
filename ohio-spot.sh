#! /bin/bash

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
    "UserData": "",
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

aws --region ${REGION} ec2 request-spot-instances --spot-price "0.03" --instance-count 1 --type "one-time" --launch-specification file://${FILE}
rm ${FILE}
