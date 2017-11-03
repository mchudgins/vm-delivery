#! /bin/bash

# check if a spot price was provided
if [[ -z "${SPOT_PRICE}" ]]; then
    BID_PRICE=0.0275
else
    BID_PRICE=${SPOT_PRICE}
fi

#
# configuration
#

REGION=us-east-1
INSTANCE_TYPE=m4.large
KEY_NAME="kp201707"
SUBNET="subnet-08849b7f"
IMAGE_STREAM=etcd

if [[ ! /bin/true ]]; then
    echo SUBNET=${SUBNET}
    exit 0
fi

# retrieve the list of ami's owned by this account
IMAGES=`aws --region ${REGION} ec2 describe-images --owners self`
#IMAGES=`cat /tmp/images.json`

# now find the latest image matching vault-seed-<date/time>
ORIGIN_DATE="0000-00-00T00:00:00.000Z"
MAX_DATE=${ORIGIN_DATE}
MAX_IMAGE_INDEX=-1

image_count=`echo ${IMAGES} | jq '.[] | length'`
for i in `seq 1 ${image_count}`; do
  var=`expr $i - 1`
  name=`echo ${IMAGES} | jq .Images[$var].Name`
  IFS='-' read -ra NAME <<< "${name//\"/}"
  if [[ ${#NAME[@]} -eq 2 ]]; then
    if [[ ${NAME[0]} == "etcd" ]]; then
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
USERDATA=$(cat <<-"_EOF_" | sed -e "s/REGION=xxx/REGION=${REGION}/" | base64 -w 0
#! /bin/bash
hostname `hostname -s`.ec2.internal

REGION=xxx
id >/tmp/id.uid
date > /tmp/cloud-final
echo NODE_NAME=etcd0 > /tmp/etcd-config
echo CLUSTER_NAME=vpc0 >> /tmp/etcd-config

systemctl start etcd
_EOF_
)

echo ${USERDATA} | base64 -d

# create the updated json launch config in a temp file
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "ImageId": ${IMAGE_ID},
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
        "PrivateIpAddress": "10.10.128.10",
        "Groups": [
            "sg-5ef8153a"
            ]
      }
    ]
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
aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=Name,Value=${IMAGE_STREAM}

#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance availabe at ${ipaddr}

# update the DNS entry for this new instance of vault-seed-${REGION}.dstcorp.io
FILE=`mktemp`
cat <<EOF >${FILE}
{
    "Comment": "Update record to reflect public IP address of instance ${instanceID}",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "vault-seed-${REGION}.dstcorp.io.",
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
#aws route53 change-resource-record-sets --hosted-zone-id ${ZONEID} --change-batch file://${FILE}
#aws --region ${REGION} ec2 create-tags --resources ${instanceID} --tags Key=DNS,Value=vault-seed-${REGION}.dstcorp.io

rm ${FILE}
