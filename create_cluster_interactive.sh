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

# FUNCTION NUMBERS
for function in ./func/*; do
   . $function
done

for graph in ./graph/*; do
   . $graph
done

check_sysctl

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


#CHECK WHICH KUBECONFIG
readValidator "Cluster Tenant Namespace : " namingvalidator K8S_TENANT_NAMESPACE
readValidator "Cluster Tenant Realm : " namingvalidator K8S_TENANT_REALM
readValidator "Cluster Name : " namingvalidator K8S_CLUSTER_NAME
readValidator "How many Control Planes : " nodesnumvalidator K8S_MASTER_NODES
readValidator "How Many Workers : " nodesnumvalidator K8S_WORKER_NODES

echo "Interactive Kubernetes cluster creation, provide parameters"

#EXPORT VARIABLES PER ENVSUBST
export K8S_TENANT_NAMESPACE=$K8S_TENANT_NAMESPACE
export K8S_TENANT_REALM=$K8S_TENANT_REALM
export K8S_CLUSTER_NAME=$K8S_CLUSTER_NAME
export K8S_MASTER_NODES=$K8S_MASTER_NODES
export K8S_WORKER_NODES=$K8S_WORKER_NODES


PS3='Choose kubernetes cluster destination environment: '
select environment in "Docker" "Kubevirt(in Kind)" "Kubevirt(External Cluster)"; do
  export environment
    if [[ $REPLY == "0" ]]; then
        echo 'Exiting!' >&2
        exit
    else
        echo "Selected character: $environment"
        case $environment in
          "Docker")
            . create_docker_cluster.sh
            break
            ;;
          "Kubevirt(in Kind)")
            . create_kubevirt_cluster.sh
            break
            ;;
          "Kubevirt(External Cluster)")
            . create_kubevirt_external_cluster.sh
            break
            ;;
          *) 
            echo "Invalid option $REPLY"
            ;;
        esac
  fi
done

