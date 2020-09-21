#!/bin/bash

# TODO - determine and provision latest version of EKS dynamically
# TODO - install kubectl aligned with the EKS version 
# TODO - remove dependency on public dockerhub for flog
# TODO - package as cloudformation
# TODO - clean up user data

# Global variables
CLUSTER_NAME=jam-eks-cluster-$RANDOM
echo "export CLUSTER_NAME=${CLUSTER_NAME}" | tee -a ~/.bash_profile

# installing prerequisites
yum update -y
yum install -y amazon-cloudwatch-agent jq curl wget gettext bash-completion moreutils
mkdir -p /tmp/

rm -vf ${HOME}/.aws/credentials
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
echo "export ACCOUNT_ID=${ACCOUNT_ID}" | tee -a ~/.bash_profile
echo "export AWS_REGION=${AWS_REGION}" | tee -a ~/.bash_profile
aws configure set default.region ${AWS_REGION}
aws configure get default.region

# create KMS CMK
aws kms create-alias --alias-name alias/jam --target-key-id $(aws kms create-key --query KeyMetadata.Arn --output text)
export MASTER_ARN=$(aws kms describe-key --key-id alias/jam --query KeyMetadata.Arn --output text)
echo "export MASTER_ARN=${MASTER_ARN}" | tee -a ~/.bash_profile

# install kubectl
sudo curl --silent --location -o /usr/bin/kubectl \
    https://amazon-eks.s3.us-west-2.amazonaws.com/1.17.7/2020-07-08/bin/linux/amd64/kubectl
sudo chmod +x /usr/bin/kubectl
kubectl completion bash >>  ~/.bash_completion
. /etc/profile.d/bash_completion.sh
. ~/.bash_completion

# install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
mv -f -v /tmp/eksctl /usr/bin
eksctl completion bash >> ~/.bash_completion
. /etc/profile.d/bash_completion.sh
. ~/.bash_completion

# create cluster config
cat << EOF > /tmp/jam-eks-cluster.yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.17"

availabilityZones: ["${AWS_REGION}a", "${AWS_REGION}b", "${AWS_REGION}c"]

managedNodeGroups:
- name: nodegroup
  desiredCapacity: 5
  ssh:
    allow: false
    publicKeyName: LAB-KEY-PAIR

cloudWatch:
 clusterLogging:
   enableTypes: ["*"]

secretsEncryption:
  keyARN: ${MASTER_ARN}
EOF

# create log generator config - no spam
cat << EOF > /tmp/deploy.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentbit-config
data:
  # Configuration files: server, input, filters and output
  # ======================================================
  fluent-bit.conf: |
    [INPUT]
        Name              tail
        Tag               *.logs
        Path              /var/log/access_log/*.s
        DB                /var/log/access_log/logs.db
        Mem_Buf_Limit     128MB
        Refresh_Interval  1
        Tag               access_log
    [INPUT]
        Name              tail
        Tag               *.logs
        Path              /var/log/error_log/*.s
        DB                /var/log/error_log/logs.db
        Mem_Buf_Limit     128MB
        Refresh_Interval  1
        Tag               error_log
    [OUTPUT]
        Name              cloudwatch_logs
        Match             access_log
        region            {{region_name}}
        log_group_name    /eks/\${APPLICATION_NAME}
        log_stream_name   access_log-\${HOSTNAME}
        auto_create_group true
    [OUTPUT]
        Name              cloudwatch_logs
        Match             error_log
        region            {{region_name}}
        log_group_name    /eks/\${APPLICATION_NAME}
        log_stream_name   error_log-\${HOSTNAME}
        auto_create_group true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: application-{{id}}
  name: application-{{id}}
spec:
  replicas: {{replicas}}
  selector:
    matchLabels:
      app: application-{{id}}
  strategy: {}
  template:
    metadata:
      labels:
        app: application-{{id}}
    spec:
      # serviceAccountName: fargate
      containers:
      - name: application-{{id}}-access-log
        image: iizotov/aws-cloudwatch-jam:latest
        command: ["/bin/bash"]
        args: ["-c", "flog --format apache_common --type stdout --delay 0.1s --loop | multilog t s20000 n100 '!tai64nlocal' /var/log/access_log/"]
        volumeMounts:
        - name: varlog
          mountPath: /var/log
      - name: application-{{id}}-error-log
        image: iizotov/aws-cloudwatch-jam:latest
        command: ["/bin/bash"]
        args: ["-c", "flog --format apache_error --type stdout --delay {{delay}}s --loop | multilog t s{{flush_size}} n100 '!tai64nlocal' /var/log/error_log/"]
        volumeMounts:
        - name: varlog
          mountPath: /var/log
      - name: application-{{id}}-fluentbit
        image: amazon/aws-for-fluent-bit:latest
        ports:
          - containerPort: 2020
        env:
        - name: FLUENTD_HOST
          value: "fluentd"
        - name: FLUENTD_PORT
          value: "24224"
        - name: APPLICATION_NAME
          value: application-{{id}}
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: fluentbit-config
          mountPath: /fluent-bit/etc/
      terminationGracePeriodSeconds: 1
      volumes:
      - name: varlog
        emptyDir: {}
      - name: fluentbit-config
        configMap:
          name: fluentbit-config
EOF

# spin up cluster
eksctl create cluster -f /tmp/jam-eks-cluster.yaml

# get kubeconfig
aws eks --region ${AWS_REGION} update-kubeconfig --name ${CLUSTER_NAME}

# export the worker role name
STACK_NAME=$(eksctl get nodegroup --cluster $CLUSTER_NAME -o json | jq -r '.[].StackName')
ROLE_NAME=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME | jq -r '.StackResources[] | select(.ResourceType=="AWS::IAM::Role") | .PhysicalResourceId')
echo "export ROLE_NAME=${ROLE_NAME}" | tee -a ~/.bash_profile

# Install Container Insights
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
curl -s https://raw.githubusercontent.com/iizotov/aws-cloudwatch-jam/master/cwagent.yaml | sed "s/{{cluster_name}}/${CLUSTER_NAME}/;s/{{region_name}}/${AWS_REGION}/" | kubectl apply -f -

# deploy a bunch of non-spamming apps
for i in {1..20}
do
  cat /tmp/deploy.yaml | sed "s/{{replicas}}/1/;s/{{flush_size}}/20000/;s/{{delay}}/0.1/;s/{{id}}/$RANDOM$RANDOM/;s/{{region_name}}/${AWS_REGION}/" | kubectl apply -f -
done

# deploy a bad spammer with id 2442826818
cat /tmp/deploy.yaml | sed "s/{{replicas}}/4/;s/{{flush_size}}/10000000/;s/{{delay}}/0/;s/{{id}}/2442826818/;s/{{region_name}}/${AWS_REGION}/" | kubectl apply -f -

for i in {1..20}
do
  cat /tmp/deploy.yaml | sed "s/{{replicas}}/1/;s/{{flush_size}}/20000/;s/{{delay}}/0.1/;s/{{id}}/$RANDOM$RANDOM/;s/{{region_name}}/${AWS_REGION}/" | kubectl apply -f -
done

# cron job - kill one deployment, replace with another

cat << EOF > /tmp/rotate.sh
#!/bin/bash

DEPLOYMENT_TO_KILL=\$(kubectl get deploy -o json | jq -r '.items[].metadata.name' | grep -v 2442826818 | sort | head -1)
kubectl delete deployment \$DEPLOYMENT_TO_KILL
cat /tmp/deploy.yaml | sed "s/{{replicas}}/1/;s/{{flush_size}}/20000/;s/{{delay}}/0.1/;s/{{id}}/\$RANDOM\$RANDOM/;s/{{region_name}}/${AWS_REGION}/" | kubectl apply -f -

EOF
chmod +x /tmp/rotate.sh

# installing crontab
crontab -l | { cat; echo "SHELL=/bin/bash"; } | crontab -
crontab -l | { cat; echo "*/5 * * * * /tmp/rotate.sh"; } | crontab -

echo "Done"
