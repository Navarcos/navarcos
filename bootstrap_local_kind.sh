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

# Check prerequisites
required_commands=("date" "cut" "jq" "tr" "base64" "kind" "yq" "envsubst" "helm" "kubectl" "curl" "sed" "clusterctl")
missing_commands=()
for cmd in "${required_commands[@]}"; do
    check_command "$cmd"
done
if [ ${#missing_commands[@]} -ne 0 ]; then  # Check if the array of missing commands is not empty
    echo "$(r_echo NAVARCOS:ERROR:) Prerequisites failed! Missing the following applications"
    for cmd in "${missing_commands[@]}"; do
        echo "  - $cmd"
    done
    exit 1  # if there are missing commands
else
    echo "$(g_echo NAVARCOS:INFO:) All required commands are installed. Proceeding"
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

# ENV variables in commons.env are generated from NAVARCOS_VALUES_FILE
source ./commons.env

# Execute the command and store the output as an array
mapfile -t CLUSTERS_ARRAY < <(kind get clusters)
# Check if Navarcos cluster is present in the array
CLUSTER_EXISTS=false
for CLUSTER in "${CLUSTERS_ARRAY[@]}"; do
    if [[ "${CLUSTER}" == "${NAVARCOS_KIND_CLUSTERNAME}" ]]; then
        CLUSTER_EXISTS=true
        break
    fi
done

if [ "${CLUSTER_EXISTS}" = true ]; then
    echo "$(y_echo NAVARCOS:WARN:) The cluster '${NAVARCOS_KIND_CLUSTERNAME}' already exists"

    # Ask the user for deletion or to stop the script
    read -p "$(y_echo NAVARCOS:) (d)elete/(r)euse '${NAVARCOS_KIND_CLUSTERNAME}' cluster [this will continue the installation] or E(x)it? (d/r/x): " ANSWER
    if [ "${ANSWER}" == "d" ]; then
        # Execute the command to delete the cluster
        kind delete cluster --name ${NAVARCOS_KIND_CLUSTERNAME}
        echo "$(y_echo NAVARCOS:WARN:) Cluster '${NAVARCOS_KIND_CLUSTERNAME}' has been deleted"
    elif [ "${ANSWER}" == "r" ]; then
        NAVARCOS_KIND_REUSE=true
        echo "$(g_echo NAVARCOS:INFO:) Reusing '${NAVARCOS_KIND_CLUSTERNAME}' cluster"
    else
        NAVARCOS_KIND_UPDATE=true
        echo "$(g_echo NAVARCOS:INFO:) Updating values then exit"
    fi
else
    echo "$(g_echo NAVARCOS:INFO:) Cluster '${NAVARCOS_KIND_CLUSTERNAME}' does not exist"
fi

# Create kind cluster
if [ "${NAVARCOS_KIND_UPDATE}" != true ]; then
    echo "$(g_echo NAVARCOS:INFO:) Create kind '${NAVARCOS_KIND_CLUSTERNAME}' cluster"
    if [ "${NAVARCOS_KIND_REUSE}" != true ]; then
        kind create cluster --config ${LOCALKINDCONFIG} --name ${NAVARCOS_KIND_CLUSTERNAME}
    fi
    if [ $? != 0 ] ; then
        echo "$(r_echo NAVARCOS:ERROR: Failed to deploy Kind Cluster, check logs)"
        exit 1
    fi
fi

# Get Navarcos Kind Ingress IP address to access services
export NAVARCOS_DOMAIN_SUFFIX=".$(kubectl get node navarcos-control-plane -o jsonpath='{.status.addresses[0].address}').nip.io"
echo "$(g_echo NAVARCOS:INFO:) Kind Navarcos domain: $(g_echo ${NAVARCOS_DOMAIN_SUFFIX})"

# Refresh ENV variables to account for Kind Navarcos Ingress IP
source ./commons.env

# Files to be rendered in ./bootstrap_out/
declare -A YAML_FILES
YAML_FILES[./bootstrap_local_kind_yaml/keycloak.values.TEMPLATE.yaml]="keycloak.values.yaml"
YAML_FILES[./bootstrap_local_kind_yaml/plancia.configmaps.TEMPLATE.yaml]="plancia.configmaps.yaml"

# Check for already rendered out files and backup them
for ORPHAN in ${BOOTSTRAP_OUT}/*
do
    [ -f "${ORPHAN}" ] || continue
    if [ "${ORPHAN##*/}" != "DoNotRemove.md" ]; then
        mkdir ${PARKINGFOLDER} > /dev/null 2>&1
        mv "${ORPHAN}" "${PARKINGFOLDER}"
        echo "$(g_echo NAVARCOS:INFO:) File $(g_echo ${ORPHAN}) PARKED in ${PARKINGFOLDER}"
    fi
done

# Render files in ./bootstrap_out/
for i in "${!YAML_FILES[@]}"
do
    echo "$(g_echo NAVARCOS:INFO:) Rendering ${YAML_FILES[$i]} from $i"
    envsubst < "$i" > "${BOOTSTRAP_OUT}/${YAML_FILES[$i]}"
    yq "${YAML_FILES[$i]}" > /dev/null
    if [ $? != 0 ] ; then
        echo "$(r_echo NAVARCOS:ERROR:) Invalid YAML in ${YAML_FILES[$i]}"
        exit 1
    fi
done

if [ "${NAVARCOS_KIND_UPDATE}" == true ]; then
    echo "$(g_echo NAVARCOS:INFO:) Values updated. Exiting"
    exit 0
fi

# Wait for kube-scheduler 
echo "$(g_echo NAVARCOS:INFO:) Waiting for kube scheduler"
kubectl wait --timeout 300s --for=condition=ready pod -n kube-system -l component=kube-scheduler
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error waiting for Kind kube-scheduler to be ready"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Install Tigera/Calico Operator"
helm upgrade calico-crds tigera-crds-navarcos --install --wait --create-namespace --namespace tigera-operator \
    --version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing Tigera/Calico Operator CRDs"
    exit 1
fi
helm upgrade calico tigera-operator-navarcos --install --wait --namespace tigera-operator \
    --version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing Tigera/Calico Operator"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Install metrics-server"
helm upgrade metrics-server metrics-server-navarcos --install --wait --namespace kube-system \
    --version $(yq '.navarcos.metricsServer.targetRevision' < values.providers.yaml) \
    --repo https://navarcos.github.io/navarcos-charts \
    --values ./bootstrap_yaml/metrics-server.values.yaml
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing metrics-server"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Install cert-manager"
helm upgrade cert-manager cert-manager --install --wait --create-namespace --namespace cert-manager \
    --version $(yq '.clusterapi.certManager.targetRevision' < values.providers.yaml) \
    --repo https://charts.jetstack.io \
    --values ./bootstrap_yaml/cert-manager.values.yaml
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing cert-manager"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Create self-signed cert-manager ClusterIssuer"
kubectl apply -f ./bootstrap_yaml/cert-manager_self-signed.yaml
kubectl wait --for=condition=ready certificate -n cert-manager navarcos-ca
NAVARCOS_CA=$(kubectl get secret navarcos-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}'|base64 -d)
echo "$(g_echo NAVARCOS:INFO:) Kind Navarcos CA certificate"
echo "${NAVARCOS_CA}"

echo "$(g_echo NAVARCOS:INFO:) Install ClusterAPI"
clusterctl init --wait-providers \
    --core cluster-api:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --bootstrap kubeadm:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --control-plane kubeadm:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --infrastructure docker:$(yq '.clusterapi.capi.targetRevision' < values.providers.yaml) \
    --infrastructure vsphere:$(yq '.clusterapi.vsphere.targetRevision' < values.providers.yaml) \
    --ipam incluster:$(yq '.clusterapi.ipam.targetRevision' < values.providers.yaml) \
    --config ./bootstrap_yaml/clusterctl-IPAM.config.yaml
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing ClusterAPI"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Install Ingress NGINX"
helm upgrade ingress-nginx ingress-nginx --install --wait --create-namespace --namespace ingress-nginx \
    --version $(yq '.navarcos.ingressNginx.targetRevision' < values.providers.yaml) \
    --repo https://kubernetes.github.io/ingress-nginx \
    --values https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/hack/manifest-templates/provider/kind/values.yaml \
    --values ./bootstrap_yaml/ingress-nginx.values.yaml
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing Ingress NGINX"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Waiting for NGINX to be ready"
kubectl wait --timeout 180s --for=condition=ready pod -n ingress-nginx \
    -l app.kubernetes.io/component=controller \
    -l app.kubernetes.io/name=ingress-nginx

echo "$(g_echo NAVARCOS:INFO:) Install Keycloak"
helm upgrade keycloak keycloak --install --wait --create-namespace --namespace keycloak \
    --version $(yq '.navarcos.keycloak.targetRevision' < values.providers.yaml) \
    --repo https://charts.bitnami.com/bitnami \
    --values ${BOOTSTRAP_OUT}/keycloak.values.yaml
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error installing Keycloak"
    exit 1
fi
echo "$(g_echo NAVARCOS:INFO:) Keycloak reachable at https://$(yq '.ingress.hostname' < ${BOOTSTRAP_OUT}/keycloak.values.yaml)"

echo "$(g_echo NAVARCOS:INFO:) Waiting for Keycloak to be ready"
kubectl wait --timeout 300s --for=condition=ready pod -n keycloak \
    -l app.kubernetes.io/component=keycloak \
    -l app.kubernetes.io/name=keycloak
if [ $? != 0 ];then
    echo "$(r_echo NAVARCOS:ERROR:) Error on waiting for Keycloak to be ready"
    exit 1
fi

echo "$(g_echo NAVARCOS:INFO:) Create plancia environment"
kubectl apply -f ./bootstrap_yaml/plancia.namespace.yaml
kubectl apply -f ${BOOTSTRAP_OUT}/plancia.configmaps.yaml
kubectl create secret generic navarcos-ca --from-literal=ca.crt="${NAVARCOS_CA}" --namespace plancia

echo "$(g_echo NAVARCOS:INFO:) Getting Keycloak token"
# Get Keycloak admin password from K8s
NAVARCOS_KEYCLOAK_PASSWORD=$(kubectl get secret keycloak -n keycloak -o json|jq -r '.data."admin-password"'|base64 -d)
# Get Keycloak token for admin user
NAVARCOS_KEYCLOAK_TOKEN=$(curl -s -k -d "client_id=admin-cli" -d "username=ncadmin" -d "password=${NAVARCOS_KEYCLOAK_PASSWORD}" -d "grant_type=password" "${NAVARCOS_KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" | sed -n 's|.*"access_token":"\([^"]*\)".*|\1|p')

echo "$(g_echo NAVARCOS:INFO:) Create Plancia client in Keycloak master realm"
# Create plancia client in master realm
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -X POST -d "$(cat "./bootstrap_data/keycloak_client.json")" -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms/master/clients")
# Get plancia client data
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms/master/clients")
# Extract plancia client secret
export NAVARCOS_PLANCIA_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="plancia") | .secret')
echo "$(g_echo NAVARCOS:INFO:) Plancia master Secret= ${NAVARCOS_PLANCIA_SECRET}"
# Get plancia service account
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms/master/users?exact=true&username=service-account-plancia")
# Extract plancia service account ID
export NAVARCOS_PLANCIA_SA_ID=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | .id')
echo "$(g_echo NAVARCOS:INFO:) Plancia master Service Account ID= ${NAVARCOS_PLANCIA_SA_ID}"
# Create K8s secret for plancia service account in master realm
[ -z "${NAVARCOS_PLANCIA_SECRET}" ] || kubectl create secret generic plancia-keycloak-client --namespace plancia \
    --from-literal=clientId=plancia \
    --from-literal=clientSecret=${NAVARCOS_PLANCIA_SECRET} \
    --from-literal=realm=master

echo "$(g_echo NAVARCOS:INFO:) Adding admin roles to Plancia client in master realm"
# Get master realm roles for plancia service account
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms/master/users/${NAVARCOS_PLANCIA_SA_ID}/role-mappings/realm/available")
# Extract role IDs for admin and create-realm
export NAVARCOS_KEYCLOAK_ROLE_ADMIN_ID=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.name=="admin") | .id')
export NAVARCOS_KEYCLOAK_ROLE_REALM_ID=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.name=="create-realm") | .id')
# Add roles to plancia service account
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -X POST -d "$(envsubst < "./bootstrap_data/keycloak_serviceaccount.TEMPLATE.json")" -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms/master/users/${NAVARCOS_PLANCIA_SA_ID}/role-mappings/realm")

echo "$(g_echo NAVARCOS:INFO:) Create Keycloak Navarcos realm"
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -X POST -d "$(envsubst < "./bootstrap_data/keycloak_realm.TEMPLATE.json")" -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms")

echo "$(g_echo NAVARCOS:INFO:) Create plancia clients secrets"
NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" "${NAVARCOS_KEYCLOAK_URL}/admin/realms/Navarcos/clients")
# Extract client secrets
export NAVARCOS_GITLAB_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="gitlab-navarcos") | .secret')
export NAVARCOS_HARBOR_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="harbor-navarcos") | .secret')
export NAVARCOS_OPENSEARCH_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="opensearch-navarcos") | .secret')
export NAVARCOS_OAUTH2PROXY_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="oauth2proxy-navarcos") | .secret')
export NAVARCOS_PLANCIA_BE_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="plancia-backend") | .secret')
export NAVARCOS_GRAFANA_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq -r '.[] | select(.clientId=="grafana-navarcos") | .secret')
# Create K8s secret for plancia-backend service account in Navarcos realm
[ -z "${NAVARCOS_PLANCIA_BE_SECRET}" ] || kubectl create secret generic plancia-backend-client --namespace plancia \
    --from-literal=clientId=plancia-backend \
    --from-literal=clientSecret=${NAVARCOS_PLANCIA_BE_SECRET} \
    --from-literal=realm=Navarcos
# Create K8s secret for plancia-frontend account in Navarcos realm
[ -z "${NAVARCOS_PLANCIA_BE_SECRET}" ] || kubectl create secret generic plancia-frontend-client --namespace plancia \
    --from-literal=clientId=plancia \
    --from-literal=realm=Navarcos

if [ ! -f "values.yaml" ]
then
    touch ${BOOTSTRAP_OUT}/values.yaml
    export NAVARCOS_VALUES_FILE="${BOOTSTRAP_OUT}/values.yaml"
else
    export NAVARCOS_VALUES_FILE="./values.yaml"
fi
echo "$(g_echo NAVARCOS:INFO:) Storing secrets in ${NAVARCOS_VALUES_FILE}"
# Store client secrets in values for future reference
yq -i ".navarcos.gitlab.oidcSecret = \"${NAVARCOS_GITLAB_SECRET}\"" ${NAVARCOS_VALUES_FILE}
yq -i ".navarcos.opensearch.oidcSecret = \"${NAVARCOS_OPENSEARCH_SECRET}\"" ${NAVARCOS_VALUES_FILE}
yq -i ".navarcos.grafana.oidcSecret = \"${NAVARCOS_GRAFANA_SECRET}\"" ${NAVARCOS_VALUES_FILE}
yq -i ".navarcos.harbor.oidcSecret = \"${NAVARCOS_HARBOR_SECRET}\"" ${NAVARCOS_VALUES_FILE}
yq -i ".navarcos.oauth2Proxy.oidcSecret = \"${NAVARCOS_OAUTH2PROXY_SECRET}\"" ${NAVARCOS_VALUES_FILE}
yq -i ".navarcos.plancia.backend.oidcSecret = \"${NAVARCOS_PLANCIA_BE_SECRET}\"" ${NAVARCOS_VALUES_FILE}
