#! /bin/bash

# retrieve the list of ami's owned by this account
IMAGES=`aws ec2 describe-images --owners self`
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

# create the updated yaml cloudformation template in a temp file
FILE=`mktemp`
cat <<"EOF" | sed -e "s/ImageId: .*/ImageId: ${IMAGE_ID}/g" >${FILE}
AWSTemplateFormatVersion: "2010-09-09"
Description: Launches a dev instance in ec2
Resources:
  DevInstance: #The EC2 instance we're launching
    Type: "AWS::EC2::Instance"
    Properties:
      AvailabilityZone: us-east-1e
      IamInstanceProfile: full-ec2-s3-access
      ImageId: "ami-ce1157d9"
      InstanceType: r4.large
      KeyName: "apache-test"
      NetworkInterfaces:
        -
          GroupSet:
            - "sg-5ef8153a"
          AssociatePublicIpAddress: true
          DeviceIndex: 0
          DeleteOnTermination: true
          SubnetId: "subnet-6e8b8005"
      Tags:
        - Key: Name
          Value: mch-dev-test
      BlockDeviceMappings:
        -
          DeviceName: /dev/sda1
          Ebs:
            VolumeType: gp2
            DeleteOnTermination: true
            VolumeSize: 40
      UserData: !Base64 |
        #! /bin/bash
        id >/tmp/uid
        TARGET_USER=mchudgins
        VOLUME=vol-a7205872
        hostname mch-dev.dstcorp.io
        adduser --gecos 'Mike Hudgins,,,' --disabled-password ${TARGET_USER}
        aws ec2 attach-volume --region us-east-1 --volume-id ${VOLUME} \
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
EOF

#cat ${FILE}
aws cloudformation create-stack --stack-name mch-dev-test --template-body file://${FILE}
