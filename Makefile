
launch:
	aws cloudformation create-stack --stack-name mch-dev-test --template-body file:///home/mchudgins/src/vm-delivery-github/dev-instance.yaml
	
clean:
	aws cloudformation delete-stack --stack-name mch-dev-test
