#!/bin/bash
# Copyright (c) 2024 Activa Digital.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# clusterctl generate cluster capi-quickstart \
#   --infrastructure="kubevirt" \
#   --flavor lb \
#   --kubernetes-version ${CAPK_GUEST_K8S_VERSION} \
#   --control-plane-machine-count=1 \
#   --worker-machine-count=1 \
#   > capi-quickstart.yaml

  # kubectl apply -f capi-quickstart.yaml

unset KUBECONFIG

# Import utility functions
for function in ./func/*; do
   . $function
done

for graph in ./graph/*; do
   . $graph
done
echo -e "$HEADER"

# Check if in "root" directory
if [ ! -d "bootstrap_local_kind_yaml" ]
then
    echo "$(r_echo NAVARCOS:ERR:) Start this script from 'root' directory"
    exit 1
fi

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

# Check for sysctls values needed by kubevirt clusters
check_sysctl



mapfile -t kubeconfigs < <(ls -pb $HOME/.kube/ | grep -v / | grep -E -v "^$|^#")
kubeconfigs+=("CUSTOM")
PS3='select external cluster KUBECONFIG to deploy kubevirt cluster (from your .kube folder), or select CUSTOM to provide custom fullpath :'
select kube in "${kubeconfigs[@]}"; do
    if [[ $REPLY == "0" ]]; then
        echo 'Exiting..' >&2
        exit
    elif [[ -z $kube ]]; then
        echo 'Empty file, retry' >&2
    elif [ "$kube" == "CUSTOM" ]; then
        read -p "Insert kubeconfig fullpath: " INFRAKUBECONFIG
        break
    else
        INFRAKUBECONFIG="$HOME/.kube/$kube"
        break
    fi
done

read -p "Enter Loadbalancer IP if your LoadBalancer provider does not have an automatic IP POOL(Kube-vip), leave blank if you configured an IP range: " controlplaneloadbalancerip
export K8S_STATIC_LOADBALANCER_IP="  loadBalancerIP: $controlplaneloadbalancerip"
  

# Default variables for test managed cluster

: ${K8S_TENANT_NAMESPACE:="skafos-kubevirt-external"}
: ${K8S_TENANT_REALM:="realm-skafos-kubevirt-external"}
: ${K8S_CLUSTER_NAME:="cluster-kubevirt-external"}
: ${K8S_MASTER_NODES:="1"}
: ${K8S_WORKER_NODES:="1"}

export K8S_TENANT_NAMESPACE
export K8S_TENANT_REALM
export K8S_CLUSTER_NAME
export K8S_MASTER_NODES
export K8S_WORKER_NODES
export K8S_VERSION="1.27.14"

export CAPK_GUEST_K8S_VERSION="v1.27.14"
export CRI_PATH="/var/run/containerd/containerd.sock"
export NODE_VM_IMAGE_TEMPLATE="quay.io/capk/ubuntu-2204-container-disk:${CAPK_GUEST_K8S_VERSION}"

#
if kubectl get ns ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG} 2>&1; then
    echo "Tenant namespace exist on infra cluster!"
else
kubectl create namespace ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG}
kubectl label namespace ${K8S_TENANT_NAMESPACE} navarcos.cluster=${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}  --kubeconfig ${INFRAKUBECONFIG}

fi


kubectl create secret generic ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-external-infra-kubeconfig --from-file=kubeconfig=${INFRAKUBECONFIG} -n capk-system
kubectl label secret ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-external-infra-kubeconfig  navarcos.cluster=${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME} -n capk-system

# #this to generate secret for CCM
# cat ${INFRAKUBECONFIG} > ./bootstrap_out/infra-kubeconfig

echo "$(g_echo NAVARCOS:INFO:) Installing Kubevirt on Infra-cluster"
if kubectl get namespace kubevirt --kubeconfig=${INFRAKUBECONFIG} 2>&1; then
    echo "Kubevirt operator exist!"
else
# get KubeVirt version

KV_VER=$(curl -s "https://api.github.com/repos/kubevirt/kubevirt/releases/latest" | jq -r ".tag_name")
# deploy required CRDs
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VER}/kubevirt-operator.yaml" --kubeconfig=${INFRAKUBECONFIG}
# deploy the KubeVirt custom resource
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VER}/kubevirt-cr.yaml" --kubeconfig=${INFRAKUBECONFIG}
kubectl wait -n kubevirt kv kubevirt --for=condition=Available --timeout=10m
fi

#install CDI cr and operator
echo "$(g_echo NAVARCOS:INFO:) Installing Containerized Data Importer on Infra-cluster"
if kubectl get namespace cdi  2>&1 --kubeconfig=${INFRAKUBECONFIG} ; then
    echo "CDI exist!"
else

export TAG=$(curl -s -w %{redirect_url} https://github.com/kubevirt/containerized-data-importer/releases/latest)
export VERSION=$(echo ${TAG##*/})
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-operator.yaml --kubeconfig=${INFRAKUBECONFIG} 
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-cr.yaml --kubeconfig=${INFRAKUBECONFIG}
fi


echo "$(g_echo NAVARCOS:INFO:) Waiting for CDI"
until kubectl wait --timeout 300s --for=condition=ready pod -l cdi.kubevirt.io=cdi-operator -n cdi  --kubeconfig=${INFRAKUBECONFIG} 2>/dev/null; do
echo CDI operator still not ready
sleep 10; 
done

echo "$(g_echo NAVARCOS:INFO:) Waiting for CDI"
until kubectl wait --timeout 300s --for=condition=ready pod -l cdi.kubevirt.io=cdi-apiserver -n cdi --kubeconfig=${INFRAKUBECONFIG} 2>/dev/null; do
echo CDI apiserver still not ready
sleep 10; 
done

echo "$(g_echo NAVARCOS:INFO:) Waiting for CDI"
until kubectl wait --timeout 300s --for=condition=ready pod -l     cdi.kubevirt.io=cdi-deployment -n cdi --kubeconfig=${INFRAKUBECONFIG} 2>/dev/null; do
echo CDI deployment still not ready
sleep 10; 
done


echo "$(g_echo NAVARCOS:INFO:) Installing Kubevirt-manager bundled"
if     kubectl get namespace kubevirt-manager --all-namespaces 2>&1 --kubeconfig=${INFRAKUBECONFIG} ; then
    echo "kubevirt-manager exist!"
else
# install kubevirt manager
    kubectl apply -f https://raw.githubusercontent.com/kubevirt-manager/kubevirt-manager/main/kubernetes/bundled.yaml --kubeconfig=${INFRAKUBECONFIG}
fi

export NAVARCOS_CA=$(kubectl get secret navarcos-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}'|base64 -d)
echo "$(g_echo NAVARCOS:INFO:) Kind Navarcos CA certificate"
echo "${NAVARCOS_CA}"



NAVARCOS_KEYCLOAK_URL=$(yq '.ingress.hostname' < ./bootstrap_out/keycloak.values.yaml)
export K8S_OIDC_PROVIDER="https://${NAVARCOS_KEYCLOAK_URL}/realms/${K8S_TENANT_REALM}"
echo "$(g_echo NAVARCOS:INFO:) OIDC Provider is ${K8S_OIDC_PROVIDER}"

echo "$(g_echo NAVARCOS:INFO:) Rendering cluster resources"
export NAVARCOS_CA=$(echo "$NAVARCOS_CA" | sed -r 's/^/              /')
envsubst < "./bootstrap_external_kubevirt/k8s-clusterapi-kubevirt-navarcos.TEMPLATE.yaml" > "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster.yaml"
envsubst < "./bootstrap_external_kubevirt/keycloak_realm.TEMPLATE.json" > "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.keycloak.realm.json"

# give datavolume clone permission
echo "$(g_echo NAVARCOS:INFO:) Creating clone permission for base image dataVolume on Infra-cluster"
kubectl create rolebinding vm-clone-permissions${K8S_TENANT_NAMESPACE} \
    --clusterrole=edit \
    --serviceaccount=${K8S_TENANT_NAMESPACE}:default \
    --namespace=default \
    --kubeconfig=${INFRAKUBECONFIG}

    

echo "$(g_echo NAVARCOS:INFO:) Getting Keycloak token"
# Get Keycloak admin password from K8s
NAVARCOS_KEYCLOAK_PASSWORD=$(kubectl get secret keycloak -n keycloak -o json|jq -r '.data."admin-password"'|base64 -d)
# Get Keycloak token for admin user
NAVARCOS_KEYCLOAK_TOKEN=$(curl -s -k -d "client_id=admin-cli" -d "username=ncadmin" -d "password=${NAVARCOS_KEYCLOAK_PASSWORD}" -d "grant_type=password" "https://${NAVARCOS_KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" | sed -n 's|.*"access_token":"\([^"]*\)".*|\1|p')

echo "$(g_echo NAVARCOS:INFO:) Create Keycloak ${K8S_TENANT_REALM} realm"
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -X POST -d "$(cat ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.keycloak.realm.json)" -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "https://${NAVARCOS_KEYCLOAK_URL}/admin/realms")
echo ${NAVARCOS_KEYCLOAK_RESULT}


echo "$(g_echo NAVARCOS:INFO:) Creating ${K8S_TENANT_NAMESPACE} namespace on manager"
kubectl create namespace ${K8S_TENANT_NAMESPACE}

#create cluster
echo "$(g_echo NAVARCOS:INFO:) Creating ${K8S_CLUSTER_NAME} cluster in ${K8S_TENANT_NAMESPACE} namespace on manager"
kubectl apply -f ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster.yaml
#create loadbalancer fix
envsubst < "./bootstrap_external_kubevirt/loadbalancer-svc.TEMPLATE.yaml" > "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.loadbalancer-svc.yaml"
kubectl apply -f "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.loadbalancer-svc.yaml" --kubeconfig=${INFRAKUBECONFIG} -n ${K8S_TENANT_NAMESPACE}
#create datavolume image
kubectl apply -f ./bootstrap_external_kubevirt/datavolume_external.yaml --kubeconfig=${INFRAKUBECONFIG}


while kubectl get secret ${K8S_CLUSTER_NAME}-kubeconfig -n ${K8S_TENANT_NAMESPACE} ; [ $? -ne 0 ] 2>/dev/null;do
  sleep 1
    echo "Waiting for the kubeconfig creation"
done

while clusterctl get kubeconfig ${K8S_CLUSTER_NAME} -n ${K8S_TENANT_NAMESPACE} > ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig 2>/dev/null; [ $? -ne 0 ];do
  sleep 1
    echo "Waiting for the kubeconfig export"
done

echo "$(g_echo NAVARCOS:INFO:) Waiting for kube scheduler"
until kubectl wait --timeout 300s --for=condition=ready pod -n kube-system -l component=kube-scheduler --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig  2>/dev/null; do 
echo kube scheduler still not ready
sleep 10;
done

echo "$(g_echo "you can monitoring your cluster while installing components, you can retrive the command in ./bootstrap_out/set_kubeconfigs.txt also":)" 
echo "$(g_echo "Fish-shell":)" 
echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"
echo "$(g_echo "BASH-shell":) "
echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"

echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> ./bootstrap_out/set_kubeconfigs.txt
echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> ./bootstrap_out/set_kubeconfigs.txt
sort -u ./bootstrap_out/set_kubeconfigs.txt -o ./bootstrap_out/set_kubeconfigs.txt



while ! kubectl --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig get nodes 2>/dev/null; do
  clusterctl get kubeconfig ${K8S_CLUSTER_NAME} -n ${K8S_TENANT_NAMESPACE} > ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig
  echo "Kubevirt Cluster is still unreachable.. wait"
  sleep 10
done

echo "$(g_echo NAVARCOS:INFO:) Verifying all nodes"

EXPECTED_NODES=$((K8S_MASTER_NODES + K8S_WORKER_NODES))

# Wait until all nodes are in the Ready state
until [[ $(kubectl get nodes --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig | tail -n +2 | wc -l) -eq $EXPECTED_NODES ]]; do
    echo "Waiting for all nodes to be created..."
    # kubectl get nodes --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig
    sleep 10
done

echo "$(g_echo NAVARCOS:INFO:) All nodes has been created"

echo "$(g_echo NAVARCOS:INFO:) Installing Tigera/Calico CRDs"

while ! helm upgrade calico-crds tigera-crds-navarcos --install --wait --create-namespace --namespace tigera-operator \
    --version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig; do
echo "Retrying calico crds installation"
sleep 5
done
kubectl label ns --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig tigera-operator pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged

echo "$(g_echo NAVARCOS:INFO:) Installing Tigera/Calico Operator"

while ! helm upgrade calico tigera-operator-navarcos --install --wait --namespace tigera-operator \
    --version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig \
    --values ./bootstrap_local_kubevirt/calico-values.yaml; do 
    echo "Retrying calico operator installation"
    sleep 5
    done



echo "$(g_echo NAVARCOS:INFO:) Waiting for Calico"
until kubectl wait -n calico-system --timeout 30s --for=condition=ready pod -l app.kubernetes.io/name=calico-node --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig 2>/dev/null; do 
echo calico still not ready
sleep 10; 
done

echo "$(g_echo NAVARCOS:INFO:) Waiting for Control Plane"
until kubectl wait --timeout 30s --for=condition=ready node -l node-role.kubernetes.io/control-plane= --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig 2>/dev/null; do
echo Control Plane still not ready
sleep 10; 
done



echo "$(g_echo NAVARCOS:INFO:) Generating infra-kubeconfig for CCM"
clusterctl get kubeconfig ${K8S_CLUSTER_NAME} -n ${K8S_TENANT_NAMESPACE} > tenant-kubeconfig
cp ${INFRAKUBECONFIG} infra-kubeconfig


envsubst < ./bootstrap_external_kubevirt/cloud-config.TEMPLATE >  ./bootstrap_external_kubevirt/cloud-config
echo "$(g_echo NAVARCOS:INFO:) Installing CCM on Infra-cluster"
kubectl delete secret infra-kubeconfig -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
kubectl delete secret tenant-kubeconfig -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
kubectl delete secret cloud-config -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
kubectl create secret generic infra-kubeconfig --from-file=./infra-kubeconfig --dry-run=client -o yaml | kubectl apply -f - -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
kubectl create secret generic tenant-kubeconfig --from-file=./tenant-kubeconfig --dry-run=client -o yaml | kubectl apply -f - -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
kubectl create secret generic cloud-config --from-file=./bootstrap_external_kubevirt/cloud-config --dry-run=client -o yaml | kubectl apply -f - -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
rm infra-kubeconfig
rm tenant-kubeconfig
rm ./bootstrap_external_kubevirt/cloud-config
envsubst < ./bootstrap_external_kubevirt/kcc-deployment.TEMPLATE.yaml > ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kcc-deployment.yaml
#install CCM
kubectl apply -f ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kcc-deployment.yaml -n ${K8S_TENANT_NAMESPACE} --kubeconfig=${INFRAKUBECONFIG}
rm ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kcc-deployment.yaml

# Generate users OIDC kubeconfig
echo "$(g_echo NAVARCOS:INFO:) Generating kubeconfig for users in $(g_echo ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig)"
cp "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "https://${NAVARCOS_KEYCLOAK_URL}/admin/realms/${K8S_TENANT_REALM}/clients")
export K8S_OIDC_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq --arg skafos_clientId ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users -r '.[] | select(.clientId==$skafos_clientId) | .secret')
yq -i e '.contexts[0].context.user = "oidc" | del(.users[0]) |with(.users[0]; .name = "oidc" | with(.user.exec; .apiVersion = "client.authentication.k8s.io/v1beta1" | .command = "kubectl" | .env = null | .provideClusterInfo = false | .args = ["oidc-login","get-token","--oidc-issuer-url="+strenv(K8S_OIDC_PROVIDER),"--oidc-client-id="+strenv(K8S_TENANT_NAMESPACE)+"-"+strenv(K8S_CLUSTER_NAME)+"-users","--oidc-client-secret="+strenv(K8S_OIDC_SECRET)]))' "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"


echo "$(g_echo NAVARCOS:INFO:) Installing metrics-server"
helm upgrade metrics-server metrics-server-navarcos --install --wait --namespace kube-system \
    --version $(yq '.navarcos.metricsServer.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --values ./bootstrap_yaml/metrics-server.values.yaml \
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig

echo "$(g_echo NAVARCOS:INFO:) Verifying all nodes are Ready"

EXPECTED_NODES=$((K8S_MASTER_NODES + K8S_WORKER_NODES))

# Wait until all nodes are in the Ready state
until [[ $(kubectl get nodes --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig 2>/dev/null | grep -c " Ready ") -eq $EXPECTED_NODES ]]; do
    echo "Waiting for all nodes to become Ready..."
    kubectl get nodes --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig
    sleep 10
done

echo "$(g_echo NAVARCOS:INFO:) All nodes are Ready"

echo "$(g_echo "to access the cluster as admin set the KUBECONFIG variable:")"
echo "$(g_echo "Fish-shell":)" 
echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"
echo "$(g_echo "BASH-shell":) "
echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"

echo "##################### Info Cluster #####################" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "##### environment: $environment" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "####### namespace: ${K8S_TENANT_NAMESPACE}" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "########### realm: ${K8S_TENANT_REALM}" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "######### cluster: ${K8S_CLUSTER_NAME}" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "######## keycloak: https://${NAVARCOS_KEYCLOAK_URL}/" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "# keycloack-admin: ncadmin" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "############ bash: export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "############ fish: set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> ./bootstrap_out/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
