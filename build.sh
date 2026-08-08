ECR_REGISTRY="072875453389.dkr.ecr.us-east-1.amazonaws.com/bia"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build -t bia .
docker tag bia:latest $ECR_REGISTRY:latest
docker push $ECR_REGISTRY:latest
