#!/bin/bash
#
# specific setup for master nodes

KUBERNETES_VERSION=1.25.4

# read arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --host-ip=*)
      arg_value="${1#*=}"
      HOST_IP=(${arg_value//,/ })
      ;;
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

if [ -z $HOST_IP ]; then
  echo "ERROR: missing required arguments!"
  echo "ERROR: set the argument --host-ip=ip"
  exit 1
fi

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

# initializing the master node

mkdir -p /tmp/kubeadm

cp /vagrant/patches/kubeadm/configuration.yml /tmp/kubeadm/configuration.yml

yq eval 'select(.kind == "ClusterConfiguration").kubernetesVersion = "'$KUBERNETES_VERSION'"' -i /tmp/kubeadm/configuration.yml
yq eval 'select(.kind == "ClusterConfiguration").apiServer.extraArgs.advertise-address = "'$MASTER_IP'"' -i /tmp/kubeadm/configuration.yml
yq eval 'select(.kind == "ClusterConfiguration").networking.podSubnet = "'$POD_NETWORK_CIDR'"' -i /tmp/kubeadm/configuration.yml
yq eval 'select(.kind == "InitConfiguration").localAPIEndpoint.advertiseAddress = "'$MASTER_IP'"' -i /tmp/kubeadm/configuration.yml

sudo kubeadm init --config=/tmp/kubeadm/configuration.yml --ignore-preflight-errors=NumCPU

# wait the kube-api-server to become live

sleep=1
timeout=300

while [ $(curl --write-out %{http_code} --silent --output /dev/null -k https://$MASTER_IP:6443/livez) -ne 200 -a $sleep -lt $timeout ]; do
  echo "INFO: waiting for kube-api-server to become live..."
  sleep $sleep
  sleep=$sleep*2
done

if [ $sleep -ge $timeout ]; then
  echo "FAILED: kube-api-server is not live after $timeout seconds..."
  exit 1
else
  echo "SUCCESS: kube-api-server live check: "
  curl -k https://$MASTER_IP:6443/livez?verbose
fi

# extract the join command

mkdir -p /vagrant/.kube
sudo kubeadm token create --print-join-command | tee /vagrant/.kube/join.sh > /dev/null
chmod +x /vagrant/.kube/join.sh

echo "SUCCESS: extracted the join command!"

# extract kube config

mkdir -p /home/vagrant/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
sudo chown 1000:1000 /home/vagrant/.kube/config

export KUBECONFIG=/home/vagrant/.kube/config

sudo cp -f /etc/kubernetes/admin.conf /vagrant/.kube/config

echo "SUCCESS: extracted kubeconfig file!"

# install kubectl

sudo apt-get install --allow-downgrades -y kubectl="$KUBERNETES_VERSION"-00

sudo apt-mark hold kubectl

if [[ $(kubectl version -o json) == *"$KUBERNETES_VERSION"* ]]; then
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

mkdir -p /tmp/cni
wget -q -O /tmp/cni/weave.yaml https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
yq eval '(.items[] | select(.kind == "DaemonSet" and .metadata.name == "weave-net").spec.template.spec.containers[] | select(.name == "weave").env) += { "name": "IPALLOC_RANGE", "value": "'$POD_NETWORK_CIDR'" }' -i /tmp/cni/weave.yaml

kubectl apply -f /tmp/cni/weave.yaml

echo "SUCCESS: installed cni plugin!"

# install metrics server

mkdir -p /tmp/metrics-server
wget -q -O /tmp/metrics-server/metrics-server.yaml https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.2/components.yaml
yq eval '(select(.kind == "Deployment" and .metadata.name == "metrics-server").spec.template.spec.containers[] | select(.name == "metrics-server").args) += "--kubelet-insecure-tls"' -i /tmp/metrics-server/metrics-server.yaml

kubectl apply -f /tmp/metrics-server/metrics-server.yaml

echo "SUCCESS: installed metrics server!"

# install kubernetes dashboard 

mkdir -p /tmp/kubernetes-dashboard
wget -q -O /tmp/kubernetes-dashboard/kubernetes-dashboard.yaml https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/alternative.yaml

yq eval 'del(select(.kind == "Deployment" and .metadata.name == "kubernetes-dashboard").spec.template.spec.containers[] | select(.name == "kubernetes-dashboard").args[] | select(. == "--enable-insecure-login"))' -i /tmp/kubernetes-dashboard/kubernetes-dashboard.yaml
yq eval '(select(.kind == "Deployment" and .metadata.name == "kubernetes-dashboard").spec.template.spec.containers[] | select(.name == "kubernetes-dashboard").args) += "--enable-skip-login"' -i /tmp/kubernetes-dashboard/kubernetes-dashboard.yaml

kubectl apply -f /tmp/kubernetes-dashboard/kubernetes-dashboard.yaml -f /vagrant/patches/kubernetes-dashboard/admin-cluster-role-binding.yml -f /vagrant/patches/kubernetes-dashboard/external-service.yml

kubernetes_dashboard_port=$(kubectl get svc -n kubernetes-dashboard kubernetes-dashboard-external -o=jsonpath='{.spec.ports[0].nodePort}')
kubernetes_dashboard_url=http://$MASTER_IP:$kubernetes_dashboard_port/

echo "SUCCESS: kubernetes dashboard is installed and available at $kubernetes_dashboard_url"

# install dynamic nfs persistent volume provisioner

mkdir -p /tmp/nfs-provisioner
wget https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/archive/refs/tags/nfs-subdir-external-provisioner-4.0.17.tar.gz -q -O - | tar xz
mv nfs-subdir-external-provisioner-nfs-subdir-external-provisioner-4.0.17/deploy/{rbac.yaml,deployment.yaml,class.yaml} /tmp/nfs-provisioner/
rm -rf nfs-subdir-external-provisioner-nfs-subdir-external-provisioner-4.0.17

nfs_provisioner_namespace=$(yq '.metadata.name' /vagrant/patches/nfs-provisioner/namespace.yml)
sed -i "s/namespace:.*/namespace: $nfs_provisioner_namespace/g" /tmp/nfs-provisioner/rbac.yaml /tmp/nfs-provisioner/deployment.yaml

yq eval '(.spec.template.spec.containers[] | select(.name == "nfs-client-provisioner").env[] | select(.name == "NFS_SERVER").value) = "'$HOST_IP'"' -i /tmp/nfs-provisioner/deployment.yaml
yq eval '(.spec.template.spec.containers[] | select(.name == "nfs-client-provisioner").env[] | select(.name == "NFS_PATH").value) = "/"' -i /tmp/nfs-provisioner/deployment.yaml
yq eval '(.spec.template.spec.volumes[] | select(.name == "nfs-client-root").nfs.server) = "'$HOST_IP'"' -i /tmp/nfs-provisioner/deployment.yaml
yq eval '(.spec.template.spec.volumes[] | select(.name == "nfs-client-root").nfs.path) = "/"' -i /tmp/nfs-provisioner/deployment.yaml

yq eval '.metadata.annotations."storageclass.kubernetes.io/is-default-class" = "true"' -i /tmp/nfs-provisioner/class.yaml
yq eval '.parameters.archiveOnDelete = "true"' -i /tmp/nfs-provisioner/class.yaml

kubectl apply -f /vagrant/patches/nfs-provisioner/namespace.yml -f /tmp/nfs-provisioner/rbac.yaml -f /tmp/nfs-provisioner/deployment.yaml -f /tmp/nfs-provisioner/class.yaml

echo "SUCCESS: installed dynamic nfs persistent volume provisioner!"

# deploy resources

if [ "$(ls -A /vagrant/.resources)" ]; then
  kubectl apply -f /vagrant/.resources/
fi
