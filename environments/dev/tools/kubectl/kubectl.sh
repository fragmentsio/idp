#!/bin/bash

KUBECTL_VERSION=1.25.4

script_directory_absolute_path=$(cd $(dirname "${BASH_SOURCE:-$0}") && pwd)
parent_directory_absolute_path=$(dirname "$script_directory_absolute_path")

kubeconfig_absolute_path="$(dirname "$parent_directory_absolute_path")/infrastructure/k8s/.kube/config"
resources_absolute_path="$(dirname "$parent_directory_absolute_path")/resources"

docker run --rm --name kubectl -v $kubeconfig_absolute_path:/.kube/config -v $resources_absolute_path:/.resources bitnami/kubectl:$KUBECTL_VERSION $@
