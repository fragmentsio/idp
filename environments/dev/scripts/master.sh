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
    *)
      echo "ERROR: Unexpected argument: $1"
      exit 1
  esac
  shift
done

# install kubectl

sudo apt-get install -y kubectl="$KUBERNETES_VERSION"-00

sudo apt-mark hold kubectl

if [[ $(kubectl version) == *"$KUBERNETES_VERSION"* ]]; then
  echo "SUCCESS: kubectl is installed!"
else
  echo "FAILED: kubectl is not installed correctly..."
  exit 1
fi

# initializing the master Node

if [ -z $MASTER_IP ]; then
  echo "ERROR: missing required arguments!"
  echo "ERROR: set the argument --master-ip=ip"
  exit 1
fi

sudo kubeadm init --apiserver-advertise-address=$MASTER_IP --ignore-preflight-errors=NumCPU

# extract the join command

mkdir -p /vagrant/.vagrant/.kube/config.d
sudo kubeadm token create --print-join-command | tee /vagrant/.vagrant/.kube/config.d/join.sh > /dev/null
chmod +x /vagrant/.vagrant/.kube/config.d/join.sh

# extract kubeconfig file

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

sudo cp -i /etc/kubernetes/admin.conf /vagrant/.vagrant/.kube/config

# install cni plugin

kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
