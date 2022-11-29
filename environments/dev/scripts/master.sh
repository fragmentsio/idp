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

# extract kubeconfig file

mkdir -p /home/vagrant/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
sudo chown 1000:1000 /home/vagrant/.kube/config

sudo cp -f /etc/kubernetes/admin.conf /vagrant/.vagrant/.kube/config

echo "SUCCESS: extracted kubeconfig file!"

# install kubectl

sudo apt-get install -y kubectl="$KUBERNETES_VERSION"-00

sudo apt-mark hold kubectl

if [[ $(kubectl --kubeconfig=/home/vagrant/.kube/config version) == *"$KUBERNETES_VERSION"* ]]; then
  echo "SUCCESS: kubectl is installed!"
else
  echo "FAILED: kubectl is not installed correctly..."
  exit 1
fi

sudo apt-get install -y bash-completion
echo "
source /usr/share/bash-completion/bash_completion
alias k='kubectl --kubeconfig=/home/vagrant/.kube/config'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
" >> /home/vagrant/.bashrc
source /home/vagrant/.bashrc

# install cni plugin

wget -q -O weave.yaml https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
yq eval '(.items[] | select(.kind == "DaemonSet" and .metadata.name == "weave-net").spec.template.spec.containers[] | select(.name == "weave").env) += { "name": "IPALLOC_RANGE", "value": "'$POD_NETWORK_CIDR'" }' -i weave.yaml

kubectl --kubeconfig=/home/vagrant/.kube/config apply -f weave.yaml

echo "SUCCESS: installed cni plugin!"
