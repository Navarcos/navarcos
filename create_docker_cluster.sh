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

# Check for sysctls values needed by docker clusters
check_sysctl

# clusterctl generate cluster navarcos-docker --flavor development --infrastructure docker \
#   --kubernetes-version v1.27.13 --control-plane-machine-count=3 --worker-machine-count=3

export NAVARCOS_CA=$(kubectl get secret navarcos-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}'|base64 -d)
echo "$(g_echo NAVARCOS:INFO:) Kind Navarcos CA certificate"
echo "${NAVARCOS_CA}"

# Default variables for test managed cluster
export K8S_TENANT_NAMESPACE="skafos"
export K8S_TENANT_REALM="Skafos"
export K8S_CLUSTER_NAME="docker"
export K8S_MASTER_NODES="3"
export K8S_WORKER_NODES="3"
export K8S_VERSION="1.27.13"
NAVARCOS_KEYCLOAK_URL=$(yq '.ingress.hostname' < ./bootstrap_out/keycloak.values.yaml)
export K8S_OIDC_PROVIDER="https://${NAVARCOS_KEYCLOAK_URL}/realms/${K8S_TENANT_REALM}"
echo "$(g_echo NAVARCOS:INFO:) OIDC Provider is ${K8S_OIDC_PROVIDER}"

echo "$(g_echo NAVARCOS:INFO:) Rendering cluster resources"
export NAVARCOS_CA=$(echo "$NAVARCOS_CA" | sed -r 's/^/              /')
envsubst < "./bootstrap_local_docker/k8s-clusterapi-docker-navarcos.TEMPLATE.yaml" > "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster.yaml"
envsubst < "./bootstrap_local_docker/keycloak_realm.TEMPLATE.json" > "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.keycloak.realm.json"
envsubst < "./bootstrap_local_docker/cluster_namespaces_roles.TEMPLATE.yaml" > "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster_namespaces_roles.yaml"

echo "$(g_echo NAVARCOS:INFO:) Getting Keycloak token"
# Get Keycloak admin password from K8s
NAVARCOS_KEYCLOAK_PASSWORD=$(kubectl get secret keycloak -n keycloak -o json|jq -r '.data."admin-password"'|base64 -d)
# Get Keycloak token for admin user
NAVARCOS_KEYCLOAK_TOKEN=$(curl -s -k -d "client_id=admin-cli" -d "username=ncadmin" -d "password=${NAVARCOS_KEYCLOAK_PASSWORD}" -d "grant_type=password" "https://${NAVARCOS_KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" | sed -n 's|.*"access_token":"\([^"]*\)".*|\1|p')

echo "$(g_echo NAVARCOS:INFO:) Create Keycloak ${K8S_TENANT_REALM} realm"
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -X POST -d "$(cat ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.keycloak.realm.json)" -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "https://${NAVARCOS_KEYCLOAK_URL}/admin/realms")
echo ${NAVARCOS_KEYCLOAK_RESULT}

echo "$(g_echo NAVARCOS:INFO:) Creating ${K8S_TENANT_NAMESPACE} namespace"
kubectl create namespace ${K8S_TENANT_NAMESPACE}

echo "$(g_echo NAVARCOS:INFO:) Creating ${K8S_CLUSTER_NAME} cluster in ${K8S_TENANT_NAMESPACE} namespace"
kubectl apply -f ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster.yaml
while kubectl get secret ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kubeconfig -n ${K8S_TENANT_NAMESPACE} ; [ $? -ne 0 ];do
  sleep 1
done
kubectl get secret ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kubeconfig -n ${K8S_TENANT_NAMESPACE} --template={{.data.value}}|base64 -d > ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig
# Wait for kube-scheduler 
echo "$(g_echo NAVARCOS:INFO:) Waiting for kube scheduler"
until kubectl wait --timeout 300s --for=condition=ready pod -n kube-system -l component=kube-scheduler --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig; do sleep 1; done
echo "$(g_echo NAVARCOS:INFO:) Installing Tigera/Calico CRDs"
helm upgrade calico-crds tigera-crds-navarcos --install --wait --create-namespace --namespace tigera-operator \
    --version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig
kubectl label ns --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig tigera-operator pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged
echo "$(g_echo NAVARCOS:INFO:) Installing Tigera/Calico Operator"
helm upgrade calico tigera-operator-navarcos --install --wait --namespace tigera-operator \
    --version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig
echo "$(g_echo NAVARCOS:INFO:) Installing metrics-server"
helm upgrade metrics-server metrics-server-navarcos --install --wait --namespace kube-system \
    --version $(yq '.navarcos.metricsServer.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --values ./bootstrap_yaml/metrics-server.values.yaml \
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig

echo "$(g_echo NAVARCOS:INFO:) Creating ${K8S_TENANT_NAMESPACE}-(dev|test|prod) namespaces and Bindings"
kubectl apply -f ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster_namespaces_roles.yaml\
    --kubeconfig ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig

# Generate users OIDC kubeconfig
echo "$(g_echo NAVARCOS:INFO:) Generating kubeconfig for users in $(g_echo ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig)"
cp "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "https://${NAVARCOS_KEYCLOAK_URL}/admin/realms/${K8S_TENANT_REALM}/clients")
export K8S_OIDC_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq --arg skafos_clientId ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users -r '.[] | select(.clientId==$skafos_clientId) | .secret')
yq -i e '.contexts[0].context.user = "oidc" | del(.users[0]) |with(.users[0]; .name = "oidc" | with(.user.exec; .apiVersion = "client.authentication.k8s.io/v1beta1" | .command = "kubectl" | .env = null | .provideClusterInfo = false | .args = ["oidc-login","get-token","--oidc-issuer-url="+strenv(K8S_OIDC_PROVIDER),"--oidc-client-id="+strenv(K8S_TENANT_NAMESPACE)+"-"+strenv(K8S_CLUSTER_NAME)+"-users","--oidc-client-secret="+strenv(K8S_OIDC_SECRET)]))' "./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"
