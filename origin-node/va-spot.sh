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
IMAGE_STREAM=node
CLUSTER_NAME=vpc0

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
echo NODE_NAME=master-0 > /tmp/master-config
echo CLUSTER_NAME=vpc0 >> /tmp/master-config
echo "OPENSHIFT_CONFIG=http://10.10.128.6/vpc0/default/vpc0/openshift/master/master-config.yaml" >> /tmp/master-config
echo "OPENSHIFT_HTPASSWD=http://10.10.128.6/vpc0/default/vpc0/openshift/htpasswd"                >> /tmp/master-config

cp /tmp/master-config /etc/default/openshift-master

systemctl start openshift-master
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
        "PrivateIpAddress": "10.10.128.20",
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
    --tags Key=Name,Value=${IMAGE_STREAM} Key=Cluster,Value=${CLUSTER_NAME}


#display the instance's IP ADDR
ipaddr=`aws --region ${REGION} ec2 describe-instances --instance-ids ${instanceID} | jq .Reservations[0].Instances[0].PublicIpAddress`
echo Instance available at ${ipaddr}

