#!/bin/bash

#
# variables
#

# AWS variables
PROFILE=default
REGION=eu-west-3
# Docker Hub image
DOCKER_IMAGE=jeromedecoster/ecs-lb-node
# project name
NAME=ecs-lb-node
# terraform
export TF_VAR_profile=$PROFILE


# the directory containing the script file
dir="$(cd "$(dirname "$0")"; pwd)"
cd "$dir"


log()   { echo -e "\e[30;47m ${1^^} \e[0m ${@:2}"; }        # $1 uppercase background white
info()  { echo -e "\e[48;5;28m ${1^^} \e[0m ${@:2}"; }      # $1 uppercase background green
warn()  { echo -e "\e[48;5;202m ${1^^} \e[0m ${@:2}" >&2; } # $1 uppercase background orange
error() { echo -e "\e[48;5;196m ${1^^} \e[0m ${@:2}" >&2; } # $1 uppercase background red


# log $1 in underline then $@ then a newline
under() {
    local arg=$1
    shift
    echo -e "\033[0;4m${arg}\033[0m ${@}"
    echo
}

usage() {
    under usage 'call the Makefile directly: make dev
      or invoke this file directly: ./make.sh dev'
}

# local development without docker
dev() {
    NODE_ENV=development PORT=3000 node .
}

# build the production image
build() {
    VERSION=$(jq --raw-output '.version' package.json)
    docker image build \
        --tag $DOCKER_IMAGE:latest \
        --tag $DOCKER_IMAGE:$VERSION \
        .
}

# run the built production image
run() {
    docker run \
        --detach \
        --name $NAME \
        --publish 3000:80 \
        $DOCKER_IMAGE
}

# remove the running container built production
rm() {
    [[ -z $(docker ps --format '{{.Names}}' | grep $NAME) ]] && return
    docker container rm \
        --force $NAME
}

# remove the running container built production
push() {
    VERSION=$(jq --raw-output '.version' package.json)
    docker push $DOCKER_IMAGE:latest
    docker push $DOCKER_IMAGE:$VERSION
}

# setup ecs-cli configuration and create cluster
ecs-configure-setup() {
    local cluster=$(aws ecs list-clusters \
        --query 'clusterArns' \
        --output yaml \
        --profile $PROFILE \
        --region $REGION \
        | grep /$NAME$)
    
    [[ -n "$cluster" ]] && { warn warn the cluster already exists; return; }
    
    ecs-cli configure \
        --cluster $NAME \
        --default-launch-type FARGATE \
        --config-name $NAME \
        --region $REGION

    ecs-cli configure default \
        --config-name $NAME

    ecs-cli up \
        --cluster-config $NAME \
        --aws-profile $PROFILE \
        --region $REGION \
        --tags Name=$NAME
}

# describe and define variables
ecs-describe-define() {
    VPC=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$NAME" \
        --query "Vpcs[].VpcId" \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    log VPC $VPC

    SUBNET_1=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=$NAME" \
        --query "Subnets[0].SubnetId" \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    log SUBNET_1 $SUBNET_1

    SUBNET_2=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=$NAME" \
        --query "Subnets[1].SubnetId" \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    log SUBNET_2 $SUBNET_2

    # the default security group
    SG=$(aws ec2 describe-security-groups \
        --query "SecurityGroups[?( VpcId == '$VPC' && GroupName == 'default' )].GroupId" \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    log SG $SG
}

# update security group ingress and create load balancer
ecs-security-group-load-balancer() {
    aws ec2 authorize-security-group-ingress \
        --group-id $SG \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --profile $PROFILE \
        --region $REGION \
        2>/dev/null

    # check if target group exists
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names $NAME \
        --query 'TargetGroups[0].TargetGroupArn' \
        --profile $PROFILE \
        --region $REGION \
        --output text \
        2>/dev/null)

    # create load balancer target group (must target IP)
    [[ -z "$TG_ARN" ]] && aws elbv2 create-target-group \
        --name $NAME \
        --protocol HTTP \
        --port 80 \
        --target-type ip \
        --vpc-id $VPC \
        --profile $PROFILE \
        --region $REGION \
        1>/dev/null

    # target group arn
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names $NAME \
        --query 'TargetGroups[0].TargetGroupArn' \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    log TG_ARN $TG_ARN

    # subnets ids, all in one line
    SUBNETS=$(aws ec2 describe-subnets \
        --region eu-west-3 \
        --filters Name=vpc-id,Values=$VPC \
        --query 'Subnets[].SubnetId' \
        --profile $PROFILE \
        --region $REGION \
        --output text \
        | tr '[:blank:]' ' ')
    log SUBNETS $SUBNETS
    
    # check if application load balancer exists
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --names $NAME \
        --query "LoadBalancers[0].DNSName" \
        --output text \
        --profile $PROFILE \
        --region $REGION \
        2>/dev/null)

    # create application load balancer
    [[ -z "$ALB_DNS" ]] && aws elbv2 create-load-balancer \
        --name $NAME \
        --type application \
        --subnets $SUBNETS \
        --profile $PROFILE \
        --region $REGION \
        1>/dev/null
    
    # application load balancer arn
    ALB_ARN=$(aws elbv2 describe-load-balancers \
        --names $NAME \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    log ALB_ARN $ALB_ARN

    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --names $NAME \
        --query "LoadBalancers[0].DNSName" \
        --output text \
        --profile $PROFILE \
        --region $REGION \
        2>/dev/null)
    log ALB_DNS $ALB_DNS

    # check if a listener exists
    LISTENER=$(aws elbv2 describe-listeners \
        --load-balancer-arn $ALB_ARN \
        --output text \
        --profile $PROFILE \
        --region $REGION \
        2>/dev/null)

    # add the listener to the load balancer
    [[ -z "$LISTENER" ]] && aws elbv2 create-listener \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --profile $PROFILE \
        --region $REGION \
        1>/dev/null
    
}

# create the iam role
ecs-service-role() {
    # check if the role ecsServiceRole exists
    ROLE=$(aws iam list-roles \
        --query "Roles[?RoleName == 'ecsServiceRole']" \
        --profile $PROFILE \
        --output text)
    
    # create the ecsServiceRole role
    if [[ -z "$ROLE" ]]
    then
        aws iam create-role \
                --role-name ecsServiceRole \
                --assume-role-policy-document '{
                    "Version": "2012-10-17",
                    "Statement": {
                    "Effect": "Allow",
                    "Principal": {"Service": "ec2.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                    }
                }' \
                --description AmazonEC2ContainerServiceRole \
                --profile $PROFILE \
                1>/dev/null

        aws iam attach-role-policy \
            --role-name ecsServiceRole \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole \
            --profile $PROFILE
    fi

    # check if the role ecsTaskExecutionRole exists
    ROLE=$(aws iam list-roles \
        --query "Roles[?RoleName == 'ecsTaskExecutionRole']" \
        --profile $PROFILE \
        --output text)

    # create the ecsTaskExecutionRole role
    if [[ -z "$ROLE" ]]
    then
        aws iam create-role \
                --role-name ecsTaskExecutionRole \
                --assume-role-policy-document '{
                    "Version": "2008-10-17",
                    "Statement": {
                    "Effect": "Allow",
                    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                    }
                }' \
                --description AmazonEC2ContainerServiceRole \
                --profile $PROFILE \
                1>/dev/null

        aws iam attach-role-policy \
            --role-name ecsTaskExecutionRole \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
            --profile $PROFILE
    fi
}

# create service
ecs-service-up() {
    # target group arn
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names $NAME \
        --query 'TargetGroups[0].TargetGroupArn' \
        --profile $PROFILE \
        --region $REGION \
        --output text)
    
    ecs-cli compose \
        --file docker-compose.aws.yml \
        --project-name $NAME \
        service up \
        --create-log-groups \
        --cluster-config $NAME \
        --target-group-arn "$TG_ARN" \
        --container-name site \
        --container-port 80 \
        --aws-profile $PROFILE \
        --region $REGION

    ecs-cli compose \
        --file docker-compose.aws.yml \
        --project-name $NAME \
        service ps \
        --cluster-config $NAME \
        --aws-profile $PROFILE \
        --region $REGION
}

# create and setup the cluster
ecs-create() {
    info execute ecs-configure-setup && ecs-configure-setup
    info execute ecs-describe-define && ecs-describe-define
    info execute ecs-security-group-load-balancer && ecs-security-group-load-balancer
    info execute ecs-service-role && ecs-service-role

    # create ecs-params.yml
    sed --expression "s|{{SUBNET_1}}|$SUBNET_1|" \
        --expression "s|{{SUBNET_2}}|$SUBNET_2|" \
        --expression "s|{{SG}}|$SG|" \
        ecs-params.sample.yml \
        > ecs-params.yml

    info execute ecs-service-up && ecs-service-up
}

# scale to 3
ecs-scale-up() {
    ecs-cli compose \
        --file docker-compose.aws.yml \
        --project-name $NAME \
        service scale 3 \
        --cluster-config $NAME \
        --aws-profile $PROFILE \
        --region $REGION
}

# scale to 1
ecs-scale-down() {
    ecs-cli compose \
        --file docker-compose.aws.yml \
        --project-name $NAME \
        service scale 1 \
        --cluster-config $NAME \
        --aws-profile $PROFILE \
        --region $REGION
}

# service ps
ecs-ps() {
    ecs-cli compose \
        --file docker-compose.aws.yml \
        --project-name $NAME \
        service ps \
        --cluster-config $NAME \
        --aws-profile $PROFILE \
        --region $REGION
}

# stop the running service then remove the cluster
ecs-destroy() {
    # load balancer arn
    LB_ARN=$(aws elbv2 describe-load-balancers \
        --names $NAME \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text \
        2>/dev/null)
    
    # TODO: clean up: find another test to remove 'None'
    [[ -n "$LB_ARN" && 'None' != "$LB_ARN" ]] \
        && aws elbv2 delete-load-balancer \
            --load-balancer-arn $LB_ARN

    # target group arn
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names $NAME \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text \
        2>/dev/null)

    # TODO: clean up: find another test to remove 'None'
    [[ -n "$TG_ARN" && 'None' != "$TG_ARN" ]] \
        && aws elbv2 delete-target-group \
            --target-group-arn $TG_ARN

    local cluster=$(aws ecs list-clusters \
        --query 'clusterArns' \
        --output yaml \
        | grep /$NAME$)

    [[ -z "$cluster" ]] && return

    ecs-cli compose \
        --project-name $NAME \
        service down \
        --cluster-config $NAME
    
    ecs-cli down \
        --force \
        --cluster-config $NAME
}

tf-init() {
    cd "$dir/infra"
    terraform init
}

tf-validate() {
    cd "$dir/infra"
    terraform fmt -recursive
	terraform validate
}

tf-apply() {
    cd "$dir/infra"
    terraform plan \
        -out=terraform.plan

    terraform apply \
        -auto-approve \
        terraform.plan
}

tf-scale-up() {
    export TF_VAR_desired_count=3
    tf-apply
}

tf-scale-down() {
    export TF_VAR_desired_count=1
    tf-apply
}

tf-destroy() {
    cd "$dir/infra"
    terraform destroy \
        -auto-approve
}

# if `$1` is a function, execute it. Otherwise, print usage
# compgen -A 'function' list all declared functions
# https://stackoverflow.com/a/2627461
FUNC=$(compgen -A 'function' | grep $1)
[[ -n $FUNC ]] && { info execute $1; eval $1; } || usage;
exit 0
