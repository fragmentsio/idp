#!/bin/bash
#
# specific setup for master nodes

KUBERNETES_VERSION=1.25.4

# read arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --master-ip=*)
      arg_value="${1#*=}"
      MASTER_IP=(${arg_value//,/ })
      ;;
    --pod-network-cidr=*)
      arg_value="${1#*=}"
      POD_NETWORK_CIDR=(${arg_value//,/ })
      ;;
    *)
      echo "ERROR: Unexpected argument: $1"
      exit 1
  esac
  shift
done

# initializing the master node

if [ -z $MASTER_IP ]; then
  echo "ERROR: missing required arguments!"
  echo "ERROR: set the argument --master-ip=ip"
  exit 1
fi

if [ -z $POD_NETWORK_CIDR ]; then
  echo "ERROR: missing required arguments!"
  echo "ERROR: set the argument --pod-network-cidr=cidr"
  exit 1
fi

sudo kubeadm init --apiserver-advertise-address=$MASTER_IP --pod-network-cidr=$POD_NETWORK_CIDR --ignore-preflight-errors=NumCPU

# wait the kube-api-server to become live

SLEEP=1
TIMEOUT=300

while [ $(curl --write-out %{http_code} --silent --output /dev/null -k https://$MASTER_IP:6443/livez) -ne 200 -a $SLEEP -lt $TIMEOUT ]; do
  echo "INFO: waiting for kube-api-server to become live..."
  sleep $SLEEP
  $SLEEP*=2
done

if [ $SLEEP -ge $TIMEOUT ]; then
  echo "FAILED: kube-api-server is not live after $TIMEOUT seconds..."
  exit 1
else
  echo "SUCCESS: kube-api-server live check: "
  curl -k https://$MASTER_IP:6443/livez?verbose
fi

# extract the join command

mkdir -p /vagrant/.vagrant/.kube/config.d
sudo kubeadm token create --print-join-command | tee /vagrant/.vagrant/.kube/config.d/join.sh > /dev/null
chmod +x /vagrant/.vagrant/.kube/config.d/join.sh

echo "SUCCESS: extracted the join command!"

# extract kube config

mkdir -p /home/vagrant/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
sudo chown 1000:1000 /home/vagrant/.kube/config

export KUBECONFIG=/home/vagrant/.kube/config

sudo cp -f /etc/kubernetes/admin.conf /vagrant/.vagrant/.kube/config

echo "SUCCESS: extracted kubeconfig file!"

# install kubectl

sudo apt-get install -y kubectl="$KUBERNETES_VERSION"-00

sudo apt-mark hold kubectl

if [[ $(kubectl version) == *"$KUBERNETES_VERSION"* ]]; then
  echo "SUCCESS: kubectl is installed!"
else
  echo "FAILED: kubectl is not installed correctly..."
  exit 1
fi

sudo apt-get install -y bash-completion
echo "
source /usr/share/bash-completion/bash_completion
alias k='kubectl'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
" >> /home/vagrant/.bashrc
source /home/vagrant/.bashrc

# install cni plugin

wget -q -O weave.yaml https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
yq eval '(.items[] | select(.kind == "DaemonSet" and .metadata.name == "weave-net").spec.template.spec.containers[] | select(.name == "weave").env) += { "name": "IPALLOC_RANGE", "value": "'$POD_NETWORK_CIDR'" }' -i weave.yaml

kubectl apply -f weave.yaml

echo "SUCCESS: installed cni plugin!"

# install metrics server

wget -q -O metrics-server.yaml https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.2/components.yaml
yq eval '(select(.kind == "Deployment" and .metadata.name == "metrics-server").spec.template.spec.containers[] | select(.name == "metrics-server").args) += "--kubelet-insecure-tls"' -i metrics-server.yaml

kubectl apply -f metrics-server.yaml

echo "SUCCESS: installed metrics server!"

# install kubernetes dashboard 

wget -q -O kubernetes-dashboard.yaml https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/alternative.yaml

echo "
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard-external
  namespace: kubernetes-dashboard
  labels:
    k8s-app: kubernetes-dashboard
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 9090
    nodePort: 30000
  selector:
    k8s-app: kubernetes-dashboard
" >> kubernetes-dashboard.yaml

yq 'del(select(.kind == "Deployment" and .metadata.name == "kubernetes-dashboard").spec.template.spec.containers[] | select(.name == "kubernetes-dashboard").args[] | select(. == "--enable-insecure-login"))' -i kubernetes-dashboard.yaml
yq '(select(.kind == "Deployment" and .metadata.name == "kubernetes-dashboard").spec.template.spec.containers[] | select(.name == "kubernetes-dashboard").args) += "--enable-skip-login"' -i kubernetes-dashboard.yaml

kubectl apply -f kubernetes-dashboard.yaml

kubernetes_dashboard_port=$(kubectl get svc -n kubernetes-dashboard kubernetes-dashboard-external -o=jsonpath='{.spec.ports[0].nodePort}')
kubernetes_dashboard_url=http://$MASTER_IP:$kubernetes_dashboard_port/

echo "SUCCESS: kubernetes dashboard is installed and available at $kubernetes_dashboard_url"
