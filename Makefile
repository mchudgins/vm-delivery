
launch:
	./launch.sh

clean:
	aws cloudformation delete-stack --stack-name mch-dev-test
