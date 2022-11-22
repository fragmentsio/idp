#!/bin/bash
#
# common setup for all nodes

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

# TODO: install a container runtime

# TODO: install kubeadm and kubelet

# TODO: configure kubelet to use the same cgroup driver as the container runtime
