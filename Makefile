
launch:
	./launch.sh

# sudo bin/oc cluster up --public-hostname ec2-54-243-4-236.compute-1.amazonaws.com --routing-suffix=54.243.4.236.xip.io

clean:
	aws cloudformation delete-stack --stack-name mch-dev-test
