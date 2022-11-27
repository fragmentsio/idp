#!/bin/bash
#
# common setup for all nodes

KUBERNETES_VERSION=1.25.4

# read arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --hosts=*)
      arg_value="${1#*=}"
      HOSTS=(${arg_value//,/ })
      ;;
    *)
      echo "ERROR: Unexpected argument: $1"
      exit 1
  esac
  shift
done

# TODO: create a non-root passwordless user other than vagrant and configure its ssh access

# setup hosts file

if [ -z $HOSTS ]; then
  echo "ERROR: missing required arguments!"
  echo "ERROR: set the argument --hosts=ip1:hostname1[,ipN:hostnameN]"
  exit 1
fi

hosts_file_update="\n# cluster nodes"

for host in "${HOSTS[@]}"; do
  hosts_file_update+="\n${host//:/ }"
done

sudo echo -e $hosts_file_update >> /etc/hosts

echo "SUCCESS: hosts file updated!"

# disable swap

sudo sed -i '/swap/s/^[^#]/# &/g' /etc/fstab
sudo swapoff -a

if [ $(swapon -s | wc -c) -ne 0 ]; then
  echo "ERROR: swap is not disabled correctly! exiting..."
  exit 1
else
  echo "SUCCESS: swap disabled!"
fi

# enable overlay and br_netflilter kernel modules

sudo cat << EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

echo "SUCCESS: overlay and br_netfilter kernel modules enabled!"

# enable ipv4 forwarding and bridged traffic for iptables

sudo cat << EOF > /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

echo "SUCCESS: ipv4 forwarding and bridged traffic for iptables enabled!"

# disable cgroups v2

sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="systemd.unified_cgroup_hierarchy=0 /g' /etc/default/grub
sudo update-grub

echo "SUCCESS: cgroup v2 disabled!"

# install required installation dependencies and set up keyrings directory

sudo apt-get update

sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

wget https://github.com/mikefarah/yq/releases/download/v4.30.4/yq_linux_amd64.tar.gz -O - | tar xz && sudo mv yq_linux_amd64 /usr/bin/yq

sudo mkdir -p /etc/apt/keyrings

# install a container runtime

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

sudo apt-get install -y containerd.io

sudo sed -i '/disabled_plugins/s/\(\,"cri"\|"cri"\,\|"cri"\)//g' /etc/containerd/config.toml

sudo echo '
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true
' | sudo tee -a /etc/containerd/config.toml > /dev/null

sudo systemctl restart containerd
sudo systemctl enable --now containerd

if [ $(systemctl is-active containerd) = "active" ]; then
  containerd --version
  echo "SUCCESS: containerd is installed!"
else
  echo "FAILED: containerd is not installed correctly..."
  exit 1
fi

# install kubeadm and kubelet

sudo curl -fsSLo /etc/apt/keyrings/kubernetes.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update

sudo apt-get install -y kubeadm="$KUBERNETES_VERSION"-00 kubelet="$KUBERNETES_VERSION"-00

sudo apt-mark hold kubeadm kubelet

if [[ $(kubeadm version -o short) == *"$KUBERNETES_VERSION"* ]]; then
  echo "SUCCESS: kubeadm is installed!"
else
  echo "FAILED: kubeadm is not installed correctly..."
  exit 1
fi

if [[ $(kubelet --version) == *"$KUBERNETES_VERSION"* ]]; then
  echo "SUCCESS: kubelet is installed!"
else
  echo "FAILED: kubelet is not installed correctly..."
  exit 1
fi
