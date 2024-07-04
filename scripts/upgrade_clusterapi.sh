#!/bin/bash

r_echo() {
  echo -e "\e[31m$1\e[0m"
}

g_echo() {
  echo -e "\e[32m$1\e[0m"
}

y_echo() {
  echo -e "\e[33m$1\e[0m"
}

# Helper function to decode base64
_decode_base64_url() {
  local len=$((${#1} % 4))
  local result="$1"
  if [ $len -eq 2 ]; then result="$1"'=='
  elif [ $len -eq 3 ]; then result="$1"'=' 
  fi
  echo "$result" | tr '_-' '/+' | base64 -d
}

# Function to decode JWT
# $1 => JWT to decode
# $2 => either 1 for header or 2 for body (default is 2)
decode_jwt() { _decode_base64_url $(echo -n $1 | cut -d "." -f ${2:-2}) | jq .; }

cd ..

# Check for existing values file or use test one
if [ ! -f "values.yaml" ]
then
    echo "$(y_echo NAVARCOS:WARN:) File 'values.yaml' does not exist"
    echo "$(y_echo NAVARCOS:WARN:) Using test values (in ./test/values.yaml)"
    export NAVARCOS_VALUES_FILE="./test/values.yaml"
else
    echo "$(g_echo NAVARCOS:INFO:) Using 'values.yaml'"
    export NAVARCOS_VALUES_FILE="./values.yaml"
fi

# ENV variables in commons.env are generated from NAVARCOS_VALUES_FILE
source ./commons.env

echo "$(g_echo NAVARCOS:INFO:) Upgrade cert-manager"
helm upgrade cert-manager cert-manager --install --wait --create-namespace --namespace cert-manager \
    --version $(yq '.clusterapi.certManager.targetRevision' < values.providers.yaml) \
    --repo https://charts.jetstack.io \
    --values ./bootstrap_yaml/cert-manager.values.yaml

echo "$(g_echo NAVARCOS:INFO:) Upgrade ClusterAPI providers"
clusterctl upgrade apply \
    --core cluster-api:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --bootstrap kubeadm:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --control-plane kubeadm:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --infrastructure docker:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --infrastructure vsphere:$(yq '.clusterapi.vsphere.targetRevision' < values.providers.yaml) \
    --ipam incluster:$(yq '.clusterapi.ipam.targetRevision' < values.providers.yaml) \
    --config ./bootstrap_yaml/clusterctl-IPAM.config.yaml
