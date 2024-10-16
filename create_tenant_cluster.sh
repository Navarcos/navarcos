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
unset KUBECONFIG


# Import utility functions
for function in ./func/*; do
    . $function
done

for graph in ./graph/*; do
    . $graph
done


# Check if in "root" directory
if [ ! -d "bootstrap_local_kind_yaml" ]; then
    echo "$(r_echo NAVARCOS:ERR:) Start this script from 'root' directory"
    exit 1
fi


echo -e "$HEADER"
# Check for sysctls values needed by kind, docker clusters
check_sysctl

# help usage
read -r -d '' usage << EOM
Usage:

  ./create_tenant_cluster.sh (interactive mode)
  ./create_tenant_cluster.sh auto -e [environment]
  ./create_tenant_cluster.sh [options]

Examples:

   interactive mode:
      ./create_tenant_cluster.sh

   auto mode:
      ./create_tenant_cluster.sh auto -e kubevirt

   all parameters:
      ./create_tenant_cluster.sh -e kubevirt -c cluster-kubevirt -n namespace-kubevirt -r realm-kubevirt -m 3 -w 1

Options:
  -e            supported environment in ["docker", "kubevirt", "kubevirtext", "openstack"]
  -c            cluster name
  -n            tenant namespace
  -r            keycloak tenant realm
  -m            how many control plane to deploy
  -w            how many worker nodes to deploy

EOM

# Initialize default values for the options
environment=""      # -e
clustername=""      # -c
namespace=""        # -n
realm=""            # -r
controlplanes=""    # -m
workernodes=""      # -w

installmode=""


if [ -z "$1" ]; then
    echo "$usage"
fi

if [ ! -z "$1" ]; then
    if [[ ! "$1" =~ ^[-][ecnrmw] ]];then
        if [ "$1" == "auto" ]; then
            installmode=$1
            shift
        else
            echo
            echo
            echo "$(r_echo '######### option not supported'): $1 "
            echo "$usage"
            exit 127
        fi
    fi
fi

if [ -z "$installmode" ]; then
    installmode="noauto"
fi


# Parse the command-line arguments using getopts
while getopts "e:c:n:r:m:w:h" opt; do
    case $opt in
        e)
            environment="$OPTARG"
        ;;
        c)
            clustername="$OPTARG"
        ;;
        n)
            namespace="$OPTARG"
        ;;
        r)
            realm="$OPTARG"
        ;;
        m)
            controlplanes="$OPTARG"
        ;;
        w)
            workernodes="$OPTARG"
        ;;
        h | *)
            echo "$(r_echo '######### option not supported')  "
            echo
            echo "$usage"
            exit 1
        ;;
    esac
done

if [ "$installmode" = "auto" ] && [ -z "$environment" ]; then
    installmode="noauto"
    echo "$(g_echo '######### MODE:') $installmode"
    echo "$(r_echo '######### you cannot specify automode without environment') (ex: ./create_tenant_cluster.sh auto -e kubevirt)"
    echo "######### switching to INTERACTIVE";
fi

if [ ! -z "$environment" ]; then
    if [ "$environment" = "docker" ] || [ "$environment" = "kubevirt" ] || [ "$environment" = "kubevirtext" ] || [ "$environment" = "openstack" ]; then
        echo "$(g_echo '######### installing on:') $environment"
    else
        echo "$(r_echo '######### environment not supported'): $environment "
        exit 127
    fi
fi

if [ "$installmode" = "auto" ] && [ ! -z "$environment" ]; then
    if [ -n "$clustername" ] || [ -n "$namespace" ] || [ -n "$realm" ] || [ -n "$controlplanes" ] || [ -n "$workernodes" ]; then
        # echo $clustername
        # echo $namespace
        # echo $realm
        # echo $controlplanes
        # echo $workernodes
        echo "$(r_echo '######### you cannot specify automode and custom parameters, just remove "auto" positional parameter') (ex: ./create_tenant_cluster.sh -e kubevirt -c cluster-kubevirt -n namespace-kubevirt -r realm-kubevirt -m 3 -w 1)"
        exit 127
    fi
    installmode="auto"
    echo "$(g_echo '######### MODE:') $installmode"
    echo "######### starting installation for $environment environment";
    workernodes=$(yq ".environments.${environment}.worker_nodes" < values.environments.yaml)
    controlplanes=$(yq ".environments.${environment}.control_planes" < values.environments.yaml)
    clustername=$(yq ".environments.${environment}.cluster_name" < values.environments.yaml)
    realm=$(yq ".environments.${environment}.tenant_realm" < values.environments.yaml)
    namespace=$(yq ".environments.${environment}.tenant_namespace" < values.environments.yaml)
    export K8S_TENANT_NAMESPACE=$namespace
    export K8S_TENANT_REALM=$realm
    export K8S_CLUSTER_NAME=$clustername
    export K8S_MASTER_NODES=$controlplanes
    export K8S_WORKER_NODES=$workernodes
fi



if [ "$installmode" = "noauto" ] && [ -z "$environment" ] && [ -z "$clustername" ] && [ -z "$namespace" ] && [ -z "$realm" ] && [ -z "$controlplanes" ] && [ -z "$workernodes" ]; then
    installmode="interactive"
    echo "$(g_echo 'MODE:') $installmode"
    echo "######### no parameters has been specified, starting interactive mode.."
    elif [ ! "$installmode" = "auto" ] && ([ -z "$environment" ] || [ -z "$clustername" ] || [ -z "$namespace" ] || [ -z "$realm" ] || [ -z "$controlplanes" ] || [ -z "$workernodes" ]); then
    installmode="interactive_partial"
    echo "$(g_echo 'MODE:') $installmode"
    echo "######### Some options have not been specified, proceeding with interactive mode with preset parameters"
fi



# Check for existing values file or use test one
if [ ! -f "values.yaml" ]
then
    echo "$(y_echo NAVARCOS:WARN:) File 'values.yaml' does not exist"
    echo "$(y_echo NAVARCOS:WARN:) Using test values (in ./test/values.yaml)"
    export NAVARCOS_VALUES_FILE="./test/values.yaml"
else
    echo "$(g_echo                     NAVARCOS:INFO:) Using 'values.yaml'"
    export NAVARCOS_VALUES_FILE="./values.yaml"
fi
if [ "$installmode" == "interactive" ] || [ "$installmode" == "interactive_partial" ] ; then
    # ask parameters
    
    
    if [ -z $environment ]; then
        PS3='Choose kubernetes cluster destination environment: '
        select environment in "Openstack" "Docker" "Kubevirt(in Kind)" "Kubevirt(External Cluster)"; do
            export environment
            if [[ $REPLY == "0" ]]; then
                echo 'Exiting!' >&2
                exit
            else
                echo "Selected character: $environment"
                case $environment in
                    "Docker")
                        environment="docker"
                        break
                    ;;
                    "Kubevirt(in Kind)")
                        environment="kubevirt"
                        break
                    ;;
                    "Openstack")
                        environment="openstack"
                        break
                    ;;
                    "Kubevirt(External Cluster)")
                        environment="kubevirtext"
                        break
                    ;;
                    *)
                        echo "Invalid option $REPLY"
                    ;;
                esac
            fi
        done
    fi
    
    
    
    
    if [ -z "$namespace" ]; then
        namespace=$(yq ".environments.${environment}.tenant_namespace" < values.environments.yaml)
        readValidatorexception "Cluster Tenant Namespace [default value $namespace, leave empty to use this value] : " namingvalidator namespace
        export K8S_TENANT_NAMESPACE=$namespace
    else
        readValidatorexception "Cluster Tenant Namespace [you specified: $namespace, leave empty to use this value] : " namingvalidator namespace_input
        if [ ! -z "$namespace_input" ]; then
            export K8S_TENANT_NAMESPACE=$namespace_input
        else
            export K8S_TENANT_NAMESPACE=$namespace
        fi
    fi
    if [ -z "$realm" ]; then
        realm=$(yq ".environments.${environment}.tenant_realm" < values.environments.yaml)
        readValidatorexception "Cluster Tenant Realm [default value $realm, leave empty to use this value] : " namingvalidator realm
        export K8S_TENANT_REALM=$realm
    else
        readValidatorexception "Cluster Tenant Realm [you specified: $realm, leave empty to use this value] : " namingvalidator realm_input
        if [ ! -z "$realm_input" ]; then
            export K8S_TENANT_REALM=$realm_input
        else
            export K8S_TENANT_REALM=$realm
        fi
    fi
    if [ -z "$clustername" ]; then
        clustername=$(yq ".environments.${environment}.cluster_name" < values.environments.yaml)
        readValidatorexception "Cluster Name : [default value $clustername, leave empty to use this value] :" namingvalidator clustername
        export K8S_CLUSTER_NAME=$clustername
    else
        readValidatorexception "Cluster Name : [you specified: $clustername, leave empty to use this value] :" namingvalidator clustername_input
        if [ ! -z "$clustername_input" ]; then
            export K8S_CLUSTER_NAME=$clustername_input
        else
            export K8S_CLUSTER_NAME=$clustername
        fi
    fi
    if [ -z "$controlplanes" ]; then
        controlplanes=$(yq ".environments.${environment}.control_planes" < values.environments.yaml)
        readValidatorexception "How many Control Planes [default value $controlplanes, leave empty to use this value] : " cplanesnumvalidator controlplanes
        export K8S_MASTER_NODES=$controlplanes
    else
        readValidatorexception "How many Control Planes [you specified: $controlplanes, leave empty to use this value] : " cplanesnumvalidator controlplanes_input
        if [ ! -z "$controlplanes_input" ]; then
            export K8S_MASTER_NODES=$controlplanes_input
        else
            export K8S_MASTER_NODES=$controlplanes
        fi
    fi
    if [ -z "$workernodes" ];then
        workernodes=$(yq ".environments.${environment}.worker_nodes" < values.environments.yaml)
        readValidatorexception "How Many Workers [default value $workernodes, leave empty to use this value] : " wnodesnumvalidator workernodes
        export K8S_WORKER_NODES=$workernodes
    else
        readValidatorexception "How Many Workers [you specified: $workernodes, leave empty to use this value] : " wnodesnumvalidator workernodes_input
        if [ ! -z "$workernodes_input" ]; then
            export K8S_WORKER_NODES=$workernodes_input
        else
            export K8S_WORKER_NODES=$workernodes
        fi
    fi
    
    export K8S_TENANT_NAMESPACE
    export K8S_TENANT_REALM
    export K8S_CLUSTER_NAME
    export K8S_MASTER_NODES
    export K8S_WORKER_NODES
else
    export K8S_TENANT_NAMESPACE=${namespace}
    export K8S_TENANT_REALM=${realm}
    export K8S_CLUSTER_NAME=${clustername}
    export K8S_MASTER_NODES=${controlplanes}
    export K8S_WORKER_NODES=${workernodes}
fi





if [ "$environment" == "kubevirtext" ]; then
    mapfile -t kubeconfigs < <(ls -pb $HOME/.kube/ | grep -v / | grep -E -v "^$|^#")
    kubeconfigs+=("CUSTOM")
    PS3='select external cluster KUBECONFIG to deploy kubevirt cluster (from your .kube folder), or select CUSTOM to provide custom fullpath: '
    select kube in "${kubeconfigs[@]}"; do
        if [[ $REPLY == "0" ]]; then
            echo 'Exiting..' >&2
            exit
            elif [[ -z $kube ]]; then
            echo 'Empty file, retry' >&2
            elif [ "$kube" == "CUSTOM" ]; then
            while true; do
                read -p "Insert kubeconfig fullpath: " INFRAKUBECONFIG
                if [ -f "$INFRAKUBECONFIG" ]; then
                    if [ -s "$INFRAKUBECONFIG" ]; then
                        echo "File exists and is not empty."
                        break
                    else
                        echo "Error: The file is empty. Please provide a valid kubeconfig file." >&2
                    fi
                else
                    echo "Error: The provided path is not a valid file. Please provide a valid kubeconfig file." >&2
                fi
            done
        else
            INFRAKUBECONFIG="$HOME/.kube/$kube"
            break
        fi
    done
    
    read -p "Enter Loadbalancer IP if your LoadBalancer provider does not have an automatic IP POOL(Kube-vip), leave blank if don't need (already specified range): " controlplaneloadbalancerip
    export K8S_STATIC_LOADBALANCER_IP="  loadBalancerIP: $controlplaneloadbalancerip"
    
fi

EXPECTED_NODES=$((K8S_MASTER_NODES + K8S_WORKER_NODES))

if [ "$environment" == "openstack" ]; then
    #   mkdir ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}
    #     read -p "username: " OS_USERNAME
    #     read -p "auth url: " OS_AUTH_URL
    #   read -p
    #   read -p
    
    
    
    # export OS_USER_DOMAIN_NAME=CCP_Domain_47124
    # export OS_PROJECT_DOMAIN_NAME=CCP_Domain_47124
    # export OS_REGION_NAME=Fra1
    # export OS_PROJECT_NAME="Default Project 47124"
    # export OS_TENANT_NAME="Default Project 47124"
    # export OS_AUTH_VERSION=3
    # export OS_IDENTITY_API_VERSION=3
    
    export CLUSTOUTFOLDER="./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}"
    mkdir $CLUSTOUTFOLDER
    
    ADMIN_OPENRC_PATH="./admin-openrc.sh" # Path al file openrc
    
    if [ -f "$ADMIN_OPENRC_PATH" ]; then
        echo "admin-openrc.sh is available..."
        # mv "$ADMIN_OPENRC_PATH" $CLUSTOUTFOLDER

    else
        echo "file admin-openrc.sh is not available on user_provided_data"
        while true; do
            echo "you should provide admin-openrc.sh in navarcos root folder or instead you can load variables manually:"
            echo "1) check again $ADMIN_OPENRC_PATH file "
            echo "2) manually provide variables "
            read -p "what's your choice: " choice
            
            if [[ "$choice" == "1" ]]; then
                read -p "load file ($ADMIN_OPENRC_PATH) and press enter."
                
                if [ -f "$ADMIN_OPENRC_PATH" ]; then
                    echo "admin-openrc.sh is available..."
                    # source "$ADMIN_OPENRC_PATH"
                    # read -p " we need to know which interface to use (in the future I'll list it with openstack) OS_INTERFACE_PUBLIC: " OS_INTERFACE_PUBLIC
                    # export OS_INTERFACE_PUBLIC
                    # mv "$ADMIN_OPENRC_PATH" $CLUSTOUTFOLDER
                    # echo "generating clouds.yaml..."
                    # envsubst < ./bootstrap_yaml/clouds.TEMPLATE.yaml > $CLUSTOUTFOLDER/clouds.yaml
                    break 
                else
                    echo "not found, try again."

                fi
                elif [[ "$choice" == "2" ]]; then

                read -p " OS_AUTH_URL: " OS_AUTH_URL
                export OS_AUTH_URL
                read -p " OS_PROJECT_NAME: " OS_PROJECT_NAME
                export OS_PROJECT_NAME
                read -p " OS_USERNAME: " OS_USERNAME
                export OS_USERNAME
                read -p " OS_USER_DOMAIN_NAME: " OS_USER_DOMAIN_NAME
                export OS_USER_DOMAIN_NAME
                read -p " OS_PROJECT_DOMAIN_NAME: " OS_PROJECT_DOMAIN_NAME
                export OS_PROJECT_DOMAIN_NAME
                read -p " OS_REGION_NAME: " OS_REGION_NAME
                export OS_REGION_NAME
                read -p " OS_PROJECT_NAME: " OS_PROJECT_NAME
                export OS_PROJECT_NAME
                read -p " OS_TENANT_NAME: " OS_TENANT_NAME
                export OS_TENANT_NAME
                read -p " OS_AUTH_VERSION: " OS_AUTH_VERSION
                export OS_AUTH_VERSION
                read -p " OS_IDENTITY_API_VERSION: " OS_IDENTITY_API_VERSION
                export OS_IDENTITY_API_VERSION
                read -p " OS_INTERFACE_PUBLIC: " OS_INTERFACE_PUBLIC
                export OS_INTERFACE_PUBLIC
                read -s -p " OS_PASSWORD: " OS_PASSWORD
                export OS_PASSWORD
                envsubst < ./bootstrap_yaml/admin-openrc.TEMPLATE.sh > admin-openrc.sh
                # source $CLUSTOUTFOLDER/admin-openrc.sh
                # echo "generating clouds.yaml..."
                # envsubst < ./bootstrap_yaml/clouds.TEMPLATE.yaml > $CLUSTOUTFOLDER/clouds.yaml
                break
                
                
            fi
        done

    fi
        echo "sourcing admin-openrc.sh..."
        source admin-openrc.sh
        echo "retrieving network list..."
        openstack network list -c ID -c Name
        read -p " which interface to use to expose the cluster? (Name is required) OS_INTERFACE_PUBLIC: " OS_INTERFACE_PUBLIC
        export OS_INTERFACE_PUBLIC   
                echo "generating clouds.yaml..."
        envsubst < ./bootstrap_yaml/clouds.TEMPLATE.yaml > clouds.yaml
    
        source env.rc clouds.yaml openstack
        # cat clouds.yaml
        mv "$ADMIN_OPENRC_PATH" $CLUSTOUTFOLDER
        mv clouds.yaml $CLUSTOUTFOLDER
        
    export OPENSTACK_IMAGE_NAME="ubuntu-2204kube"
    # export OPENSTACK_SSH_KEY_NAME
    # export OPENSTACK_EXTERNAL_NETWORK_ID
    export OPENSTACK_FAILURE_DOMAIN="nova"
    export OPENSTACK_DNS_NAMESERVERS="8.8.8.8"
    # export KUBERNETES_VERSION
    export OPENSTACK_CONTROL_PLANE_MACHINE_FLAVOR="s.2c4gb50"
    export OPENSTACK_NODE_MACHINE_FLAVOR="s.2c4gb50 "
    
    
    
    # export OS_DOMAIN_ID="076bf9fb3f2f4095a9662095c499cd63"
    echo "getting network ID"
    export OPENSTACK_EXTERNAL_NETWORK_ID=$(openstack network list --name ext-net -c ID -f value)
    echo "network ID: $OPENSTACK_EXTERNAL_NETWORK_ID "
    
    openstack keypair create --private-key ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_CLUSTER_NAME}-key ${K8S_CLUSTER_NAME}-key
    
    
    export OS_SECRET_KEY=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 10)
    echo "os secret key is $OS_SECRET_KEY"
    openstack application credential delete navarcos-${K8S_CLUSTER_NAME}-ccm
    openstack application credential create navarcos-${K8S_CLUSTER_NAME}-ccm --secret ${OS_SECRET_KEY} --description "Application credential for Kubernetes CCM"
    
    # --role admin
    
    export OS_CRED_ID=$(openstack application credential show navarcos-${K8S_CLUSTER_NAME}-ccm  -c id --noindent --format value)
    echo "os cred id is $OS_CRED_ID"
    
    
    
    export CLUSTOUTFOLDER="./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}"
    mkdir $CLUSTOUTFOLDER
    # envsubst < ./bootstrap_yaml/admin-openrc.TEMPLATE.sh > ${CLUSTOUTFOLDER}/admin-openrc.sh
    export TENANTKUBECONFIG="./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"
    export TENANTUSERSKUBECONFIG="./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"
    envsubst < ./bootstrap_yaml/cloud.TEMPLATE.conf > $CLUSTOUTFOLDER/cloud.conf
        
    
fi
# debug

# echo environment $environment
# echo TENANT NAMESPACE $K8S_TENANT_NAMESPACE
# echo TENANT REALM $K8S_TENANT_REALM
# echo CLUSTER NAME $K8S_CLUSTER_NAME
# echo MASTER NODES $K8S_MASTER_NODES
# echo WORKER NODES $K8S_WORKER_NODES
# echo tenant namespace ${namespace}
# echo tenant realm ${realm}
# echo cluster name ${clustername}
# echo control planes ${controlplanes}
# echo worker nodes ${workernodes}
# echo clusteroutfolder $CLUSTEROUTFOLDER
# echo tenant kubeconfig $TENANTKUBECONFIG
# echo tenantuserskubeconfig $TENANTUSERSKUBECONFIG
# echo loadbalancerIP $K8S_STATIC_LOADBALANCER_IP
# exit 1

mkdir ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}
# set infra-kubeconfig to kind (needed to avoid changing code in case of kubevirtext which use "infra-kubeconfig" for destination infra cluster)
if [ "$environment" == "kubevirt" ] || [ "$environment" == "docker" ] || [ "$environment" == "openstack" ]; then
    kind get kubeconfig --name navarcos> $CLUSTOUTFOLDER/infra-kubeconfig
    INFRAKUBECONFIG=$CLUSTOUTFOLDER/infra-kubeconfig
fi

if [ "$environment" == "docker" ]; then
    export K8S_VERSION="v1.27.13"
fi


if [ "$environment" == "openstack" ]; then
    export K8S_VERSION="v1.29.7"
fi

if [ "$environment" == "kubevirt" ] || [ "$environment" == "kubevirtext" ] ; then
    export CAPK_GUEST_K8S_VERSION="v1.27.14"
    export CRI_PATH="/var/run/containerd/containerd.sock"
    export NODE_VM_IMAGE_TEMPLATE="quay.io/capk/ubuntu-2204-container-disk:${CAPK_GUEST_K8S_VERSION}"
fi


echo "$(g_echo                     NAVARCOS:INFO:) Creating ${K8S_TENANT_NAMESPACE} namespace on Manager cluster"
if kubectl get ns ${K8S_TENANT_NAMESPACE} 2>&1; then
    echo "Tenant namespace exist on manager cluster!"
else
    kubectl create namespace ${K8S_TENANT_NAMESPACE}
    kubectl label namespace ${K8S_TENANT_NAMESPACE} navarcos.cluster=${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}
    
fi

#down there was also: [ "$environment" == "kubevirt" ] ||
if [ "$environment" == "kubevirtext" ] ;then
    echo "$(g_echo                     NAVARCOS:INFO:) Creating ${K8S_TENANT_NAMESPACE} namespace on Infra cluster"
    if kubectl get ns ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG} 2>&1; then
        echo "Tenant namespace exist on infra cluster!"
    else
        kubectl create namespace ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG}
        kubectl label namespace ${K8S_TENANT_NAMESPACE} navarcos.cluster=${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}  --kubeconfig ${INFRAKUBECONFIG}
    fi
    
    echo "$(g_echo                     NAVARCOS:INFO:) creating secret for CCM"
    kubectl create secret generic ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-external-infra-kubeconfig --from-file=kubeconfig=${INFRAKUBECONFIG} -n capk-system
    kubectl label secret ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-external-infra-kubeconfig  navarcos.cluster=${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME} -n capk-system
    
    echo "$(g_echo                     NAVARCOS:INFO:) Installing Kubevirt on Infra-cluster"
    
    if kubectl get namespace kubevirt --kubeconfig ${INFRAKUBECONFIG} 2>&1 ; then
        echo "Kubevirt operator namespace exist!"
    else
        # get KubeVirt version
        # KV_VER=$(curl -s "https://api.github.com/repos/kubevirt/kubevirt/releases/latest" | jq -r ".tag_name")
        # deploy required CRDs
        # kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VER}/kubevirt-operator.yaml" --kubeconfig ${INFRAKUBECONFIG}
        
        kubectl apply -f ./bootstrap_yaml/kubevirt-operator.yaml --kubeconfig ${INFRAKUBECONFIG}
        
        # deploy the KubeVirt custom resource
        # kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VER}/kubevirt-cr.yaml" --kubeconfig ${INFRAKUBECONFIG}
        kubectl apply -f ./bootstrap_yaml/kubevirt-cr.yaml --kubeconfig ${INFRAKUBECONFIG}
        
        kubectl wait -n kubevirt kv kubevirt --for=condition=Available --timeout=10m
    fi
    
    #install CDI cr and operator
    echo "$(g_echo                     NAVARCOS:INFO:) Installing Containerized Data Importer on Infra-cluster"
    if kubectl get namespace cdi --kubeconfig ${INFRAKUBECONFIG} 2>&1 ; then
        echo "CDI namespace exist!"
    else
        # export TAG=$(curl -s -w %{redirect_url} https://github.com/kubevirt/containerized-data-importer/releases/latest)
        # export VERSION=$(echo ${TAG##*/})
        # kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-operator.yaml --kubeconfig ${INFRAKUBECONFIG}
        # kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-cr.yaml --kubeconfig ${INFRAKUBECONFIG}
        kubectl create -f   ./bootstrap_yaml/cdi-operator.yaml --kubeconfig ${INFRAKUBECONFIG}
        kubectl create -f   ./bootstrap_yaml/cdi-cr.yaml --kubeconfig ${INFRAKUBECONFIG}
    fi
    
    
    echo "$(g_echo                     NAVARCOS:INFO:) Waiting for CDI"
    until kubectl wait --timeout 300s --for=condition=ready pod -l cdi.kubevirt.io=cdi-operator -n cdi  --kubeconfig ${INFRAKUBECONFIG} 2>/dev/null; do
        echo CDI operator still not ready
        sleep 10;
    done
    
    echo "$(g_echo                     NAVARCOS:INFO:) Waiting for CDI"
    until kubectl wait --timeout 300s --for=condition=ready pod -l cdi.kubevirt.io=cdi-apiserver -n cdi --kubeconfig ${INFRAKUBECONFIG} 2>/dev/null; do
        echo CDI apiserver still not ready
        
        sleep 10;
    done
    
    echo "$(g_echo                     NAVARCOS:INFO:) Waiting for CDI"
    until kubectl wait --timeout 300s --for=condition=ready pod -l     cdi.kubevirt.io=cdi-deployment -n cdi --kubeconfig ${INFRAKUBECONFIG} 2>/dev/null; do
        echo CDI deployment still not ready
        sleep 10;
    done
    
    
    echo "$(g_echo                     NAVARCOS:INFO:) Installing Kubevirt-manager bundled"
    if     kubectl get namespace kubevirt-manager --kubeconfig ${INFRAKUBECONFIG} 2>&1; then
        echo "kubevirt-manager exist!"
    else
        # install kubevirt manager
        # kubectl apply -f https://raw.githubusercontent.com/kubevirt-manager/kubevirt-manager/main/kubernetes/bundled.yaml --kubeconfig ${INFRAKUBECONFIG}
        kubectl apply -f ./bootstrap_yaml/bundled_kubevirtmanager.yaml --kubeconfig ${INFRAKUBECONFIG}
    fi
fi


export NAVARCOS_CA=$(kubectl get secret navarcos-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' |base64 -d)
echo "$(g_echo                     NAVARCOS:INFO:) Kind Navarcos CA certificate"
echo "${NAVARCOS_CA}"


if [ "$environment" != "kubevirtext" ];then
    # 1 this need to be created before Cluster creation cause oidc_provider is set on capi manifest
    echo "$(g_echo                     NAVARCOS:INFO:) set OIDC Provider"
    NAVARCOS_KEYCLOAK_URL=$(yq '.ingress.hostname' < ./bootstrap_out/keycloak.values.yaml)
    export K8S_OIDC_PROVIDER="https://${NAVARCOS_KEYCLOAK_URL}/realms/${K8S_TENANT_REALM}"
    echo "$(g_echo                     NAVARCOS:INFO:) OIDC Provider is ${K8S_OIDC_PROVIDER}"
    
    # 2
    echo "$(g_echo                     NAVARCOS:INFO:) Getting Keycloak token from management cluster"
    # Get Keycloak admin password from K8s
    NAVARCOS_KEYCLOAK_PASSWORD=$(kubectl get secret keycloak -n keycloak -o json|jq -r '.data."admin-password"'|base64 -d)
    # Get Keycloak token for admin user
    NAVARCOS_KEYCLOAK_TOKEN=$(curl -s -k -d "client_id=admin-cli" \
        -d "username=ncadmin" -d "password=${NAVARCOS_KEYCLOAK_PASSWORD}" \
        -d "grant_type=password" "https://${NAVARCOS_KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    | sed -n 's|.*"access_token":"\([^"]*\)".*|\1|p')
    
    # 3
    echo "$(g_echo                     NAVARCOS:INFO:) Create Keycloak ${K8S_TENANT_REALM} realm"
    envsubst < "./bootstrap_yaml/keycloak_realm.TEMPLATE.json" > "$CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.keycloak.realm.json"
    NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -X POST -d \
        "$(cat $CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.keycloak.realm.json)" \
        -H "Content-Type: application/json" -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" \
    "https://${NAVARCOS_KEYCLOAK_URL}/admin/realms")
    
    echo ${NAVARCOS_KEYCLOAK_RESULT}
    
    # 4 Generate users OIDC kubeconfig
    
    NAVARCOS_KEYCLOAK_RESULT=$(curl -s -k -H "Content-Type: application/json" \
        -H "Authorization: bearer ${NAVARCOS_KEYCLOAK_TOKEN}" \
    "https://${NAVARCOS_KEYCLOAK_URL}/admin/realms/${K8S_TENANT_REALM}/clients")
    K8S_OIDC_SECRET=$(echo "${NAVARCOS_KEYCLOAK_RESULT}" | jq --arg skafos_clientId ${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users -r '.[] | select(.clientId==$skafos_clientId) | .secret')
else
    echo "no keycloak install (apiserver could not reach keycloak on management cluster)"
fi

export NAVARCOS_CA_docker=$(echo "$NAVARCOS_CA" | sed -r 's/^/                /')
export NAVARCOS_CA_kubevirt=$(echo "$NAVARCOS_CA" | sed -r 's/^/          /')
export NAVARCOS_CA_kubevirtext=$(echo "$NAVARCOS_CA" | sed -r 's/^/          /')
echo "$(g_echo                     NAVARCOS:INFO:) Rendering cluster resources"
envsubst < "./bootstrap_yaml/k8s-clusterapi-${environment}-navarcos.TEMPLATE.yaml" > "$CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster.yaml"
if [ "$environment" == "kubevirtext" ]; then
    envsubst < "./bootstrap_yaml/loadbalancer-svc.TEMPLATE.yaml" > "$CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.loadbalancer-svc.yaml"
fi

envsubst < "./bootstrap_yaml/cluster_namespaces_roles.TEMPLATE.yaml" > "$CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster_namespaces_roles.yaml"


if [ "$environment" == "kubevirt" ] || [ "$environment" == "kubevirtext" ] ;then
    echo "$(g_echo                     NAVARCOS:INFO:) Creating clone permission for base image dataVolume on Infra-cluster"
    if kubectl get rolebindings vm-${K8S_TENANT_NAMESPACE}-clone-permissions --kubeconfig ${INFRAKUBECONFIG} 2>&1; then
        echo "Clone permission exist!"
    else
        # give datavolume clone permission
        kubectl create rolebinding vm-${K8S_TENANT_NAMESPACE}-clone-permissions \
        --clusterrole=edit \
        --serviceaccount=${K8S_TENANT_NAMESPACE}:default \
        --namespace=default \
        --kubeconfig ${INFRAKUBECONFIG}
    fi
    
    echo "$(g_echo                     NAVARCOS:INFO:) Creating datavolume cloning Ubuntu Image ${K8S_CLUSTER_NAME} on Infra cluster"
    kubectl apply -f ./bootstrap_yaml/datavolume_external.yaml --kubeconfig=${INFRAKUBECONFIG}
    
    baseimage=0
    until [ "$baseimage" -eq 100 ] 2>/dev/null; do
        baseimage=$(kubectl get datavolume import-ubuntu-disk -o custom-columns=PROGRESS:.status.progress --no-headers | awk -F'.' '{print $1}')
        
        if [[ -n $baseimage ]]; then
            if [[ "$baseimage" == "N/A" ]]; then
                ProgressBar 1 100
                sleep 5
                continue
                elif [[ "$baseimage" =~ ^[0-9]+$ ]]; then
                if [ "$baseimage" -eq 0 ]; then
                    ProgressBar 1 100
                    sleep 5
                    continue
                else
                    ProgressBar "$baseimage" 100
                    sleep 2
                fi
            fi
            
        fi        
    done
    
fi

echo

#create cluster
echo "$(g_echo                     NAVARCOS:INFO:) Creating ${K8S_CLUSTER_NAME} cluster in ${K8S_TENANT_NAMESPACE} namespace"
kubectl apply -f $CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster.yaml
if [ "$environment" == "kubevirtext" ]; then
    #fix loadbalancer
    kubectl apply -f "$CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.loadbalancer-svc.yaml" --kubeconfig=${INFRAKUBECONFIG} -n ${K8S_TENANT_NAMESPACE}
fi
while kubectl get secret ${K8S_CLUSTER_NAME}-kubeconfig -n ${K8S_TENANT_NAMESPACE} ; [ $? -ne 0 ] 2>/dev/null;do
    sleep 10
    echo "Waiting for the kubeconfig creation"
done
# fi

while clusterctl get kubeconfig ${K8S_CLUSTER_NAME} -n ${K8S_TENANT_NAMESPACE} > $TENANTKUBECONFIG; [ $? -ne 0 ];do
    sleep 1
    echo "Waiting for the kubeconfig export"
done

echo fixing permission kubeconfig
chmod 600 $TENANTKUBECONFIG


if [ "$environment" == "kubevirt" ] || [ "$environment" == "kubevirtext" ]; then
    EXPECTED_NODES=$((K8S_MASTER_NODES + K8S_WORKER_NODES))
    
    EXPECTED_DATAVOLUMES=$((K8S_MASTER_NODES + K8S_WORKER_NODES))
    processed_volumes=()
    
    
    while true; do
        # Estraggo i nomi dei DataVolume correnti
        datavolumes=($(kubectl get datavolume -n $K8S_TENANT_NAMESPACE -o jsonpath='{.items[*].metadata.name}'))
        for volume in "${datavolumes[@]}"; do
            volumeprogress=0
            if [[ ! " ${processed_volumes[@]} " =~ " ${volume} " ]]; then
                echo "$volume cloning":
                
                
                until [ "$volumeprogress" -eq 100 ] 2>/dev/null; do
                    volumeprogress=$(kubectl get datavolume $volume -o custom-columns=PROGRESS:.status.progress --no-headers -n $K8S_TENANT_NAMESPACE | awk -F'.' '{print $1}')
                    
                    
                    
                    if [[ -n $volumeprogress ]]; then
                        if [[ "$volumeprogress" == "N/A" ]]; then
                            ProgressBar 1 100
                            sleep 5
                            continue
                            elif [[ "$volumeprogress" =~ ^[0-9]+$ ]]; then
                            if [ "$volumeprogress" -eq 0 ]; then
                                ProgressBar 1 100
                                sleep 5
                                continue
                            else
                                ProgressBar "$volumeprogress" 100
                                sleep 2
                            fi
                        fi
                        
                        ProgressBar "$volumeprogress" 100
                        sleep 2
                    fi
                done
                echo
                processed_volumes+=("$volume")
            fi
        done
        
        if [ ${#processed_volumes[@]} -eq "$EXPECTED_DATAVOLUMES" ]; then
            echo
            echo "created ($EXPECTED_DATAVOLUMES) datavolume."
            break
        fi
        
        # Attendi un po' prima di ricontrollare
        sleep 10
    done
fi

echo

echo "$(g_echo                     NAVARCOS:INFO:) Waiting for kube scheduler"
until kubectl wait --timeout 300s --for=condition=ready pod -n kube-system -l component=kube-scheduler --kubeconfig $TENANTKUBECONFIG 2>/dev/null; do
    echo kube scheduler still not ready
    sleep 10;
done








if [ "$environment" != "kubevirtext" ];then
    echo "$(g_echo                     NAVARCOS:INFO:) Generating kubeconfig for users in $(g_echo $TENANTUSERSKUBECONFIG)"
    cp "$TENANTKUBECONFIG" "$TENANTUSERSKUBECONFIG"
fi

echo "$(g_echo "you can monitoring your cluster while installing components, you can retrive the command in $CLUSTOUTFOLDER/set_kubeconfigs.txt also":)"
echo "$(g_echo "Fish-shell":)"
echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"
echo "$(g_echo "BASH/zsh-shell":) "
echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"

echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> $CLUSTOUTFOLDER/set_kubeconfigs.txt
echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> $CLUSTOUTFOLDER/set_kubeconfigs.txt
sort -u $CLUSTOUTFOLDER/set_kubeconfigs.txt -o $CLUSTOUTFOLDER/set_kubeconfigs.txt


while ! kubectl --kubeconfig=$TENANTKUBECONFIG get nodes 2>/dev/null; do
    echo "Kubevirt Cluster is still unreachable.. wait"
    sleep 10
done

echo "$(g_echo                     NAVARCOS:INFO:) Verifying all nodes"



# Wait until all nodes are in the Ready state
until [[ $(kubectl get nodes --kubeconfig=$TENANTKUBECONFIG | tail -n +2 | wc -l) -eq $EXPECTED_NODES ]]; do
    echo "Waiting for all nodes to be created..."
    sleep 10
done
echo "$(g_echo                     NAVARCOS:INFO:) All nodes has been created"




if [ "$environment" == "openstack" ]; then
    kubectl --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig -n kube-system delete secret cloud-config
    
    kubectl --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig -n kube-system create secret generic cloud-config --from-file=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/cloud.conf
    
    kubectl --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig -n kube-system create secret generic cloud-config
    

    #downloaded from https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/...
    kubectl apply --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig -f ./bootstrap_yaml/cloud-controller-manager-roles.yaml
    kubectl apply --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig -f ./bootstrap_yaml/cloud-controller-manager-role-bindings.yaml
    kubectl apply --kubeconfig=./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig -f ./bootstrap_yaml/openstack-cloud-controller-manager-ds.yaml
fi





echo "$(g_echo                     NAVARCOS:INFO:) Installing Tigera/Calico CRDs"
while ! helm upgrade calico-crds tigera-crds-navarcos --install --wait --create-namespace --namespace tigera-operator \
--version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
--repo https://navarcos.github.io/navarcos-charts \
--kubeconfig $TENANTKUBECONFIG; do
    echo "Retrying calico crds installation"
    sleep 5
done






echo "$(g_echo                     NAVARCOS:INFO:) Enabling priviledged on Calico"
kubectl label ns --kubeconfig $TENANTKUBECONFIG tigera-operator pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged

echo "$(g_echo                     NAVARCOS:INFO:) Installing Tigera/Calico Operator"
while ! helm upgrade calico tigera-operator-navarcos --install --wait --namespace tigera-operator \
--version $(yq '.clusterapi.tigera.targetRevision' < values.providers.yaml) \
--repo https://navarcos.github.io/navarcos-charts \
--kubeconfig $TENANTKUBECONFIG \
--values ./bootstrap_yaml/${environment}-calico-values.yaml; do
    echo "Retrying calico operator installation"
    sleep 5
done

echo "$(g_echo                     NAVARCOS:INFO:) Waiting for Calico"
until kubectl wait -n calico-system --timeout 30s --for=condition=ready pod -l app.kubernetes.io/name=calico-node --kubeconfig $TENANTKUBECONFIG 2>/dev/null; do
    echo calico still not ready
    sleep 10;
done

echo "$(g_echo                     NAVARCOS:INFO:) Waiting for Control Plane"
until kubectl wait --timeout 30s --for=condition=ready node -l node-role.kubernetes.io/control-plane= --kubeconfig $TENANTKUBECONFIG 2>/dev/null; do
    echo Control Plane still not ready
    sleep 10;
done

if [ "$environment" == "kubevirt" ];then
    echo "$(g_echo                     NAVARCOS:INFO:) Generating infra-kubeconfig for CCM"
    CONTROLPLANEIP=$(kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[*].status.podIP}')
    clusterctl get kubeconfig ${K8S_CLUSTER_NAME} -n ${K8S_TENANT_NAMESPACE} > $CLUSTOUTFOLDER/tenant-kubeconfig
    kind get kubeconfig --name navarcos> $CLUSTOUTFOLDER/infra-kubeconfig
    sed -i "/^\s*server:/c\    server: https://$CONTROLPLANEIP:6443" $CLUSTOUTFOLDER/infra-kubeconfig
fi

if [ "$environment" == "kubevirtext" ];then
    echo "$(g_echo                     NAVARCOS:INFO:) Generating infra-kubeconfig for CCM"
    clusterctl get kubeconfig ${K8S_CLUSTER_NAME} -n ${K8S_TENANT_NAMESPACE} > $CLUSTOUTFOLDER/tenant-kubeconfig
    cp ${INFRAKUBECONFIG} infra-kubeconfig
fi

if [ "$environment" == "kubevirt" ] || [ "$environment" == "kubevirtext" ];then
    envsubst < ./bootstrap_yaml/cloud-config.TEMPLATE >  $CLUSTOUTFOLDER/cloud-config
    echo "$(g_echo                     NAVARCOS:INFO:) Installing CCM on Infra-cluster"
    kubectl create secret generic infra-kubeconfig --from-file=$CLUSTOUTFOLDER/infra-kubeconfig --dry-run=client -o yaml | kubectl apply -f - -n ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG}
    kubectl create secret generic tenant-kubeconfig --from-file=$CLUSTOUTFOLDER/tenant-kubeconfig --dry-run=client -o yaml | kubectl apply -f - -n ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG}
    kubectl create secret generic cloud-config --from-file=$CLUSTOUTFOLDER/cloud-config --dry-run=client -o yaml | kubectl apply -f - -n ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG}
    # rm infra-kubeconfig
    # rm $CLUSTOUTFOLDER/tenant-kubeconfig
    # rm $CLUSTOUTFOLDER/cloud-config
    envsubst < ./bootstrap_yaml/kcc-deployment.TEMPLATE.yaml > $CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kcc-deployment.yaml
    #install CCM
    kubectl apply -f $CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kcc-deployment.yaml -n ${K8S_TENANT_NAMESPACE} --kubeconfig ${INFRAKUBECONFIG}
    rm $CLUSTOUTFOLDER/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-kcc-deployment.yaml
fi



echo "$(g_echo                     NAVARCOS:INFO:) Installing metrics-server"
helm upgrade metrics-server metrics-server-navarcos --install --wait --namespace kube-system \
--version $(yq '.navarcos.metricsServer.targetRevision' < values.providers.yaml) \
--repo https://navarcos.github.io/navarcos-charts \
--values ./bootstrap_yaml/metrics-server.values.yaml \
--kubeconfig $TENANTKUBECONFIG

echo "$(g_echo                     NAVARCOS:INFO:) Verifying all nodes are still Ready"

if [ "$environment" == "docker" ];then
    echo "$(g_echo                     NAVARCOS:INFO:) Installing MetalLB on docker"
    if kubectl get namespace metallb-system --kubeconfig=$TENANTKUBECONFIG 2>&1 ; then
        echo "MetalLB namespace already exist!"
    else
        #Installing MetalLB on docker
        # METALLB_VER=$(curl -s "https://api.github.com/repos/metallb/metallb/releases/latest" | jq -r ".tag_name")
        # kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VER}/config/manifests/metallb-native.yaml" --kubeconfig=$TENANTKUBECONFIG
        kubectl apply -f ./bootstrap_yaml/metallb.yaml --kubeconfig=$TENANTKUBECONFIG
        kubectl wait pods -n metallb-system -l app=metallb,component=controller --for=condition=Ready --timeout=10m --kubeconfig=$TENANTKUBECONFIG
        kubectl wait pods -n metallb-system -l app=metallb,component=speaker --for=condition=Ready --timeout=2m --kubeconfig=$TENANTKUBECONFIG
        echo "$(g_echo                     NAVARCOS:INFO:) Installed MetalLB on docker"
        
        GW_IP=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' kind)
        NET_IP=$(echo ${GW_IP} | sed -E 's|^([0-9]+\.[0-9]+)\..*$|\1|g')
    fi
    
  cat <<EOF | sed -E "s|172.19|${NET_IP}|g" | kubectl apply --kubeconfig=$TENANTKUBECONFIG -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: capi-ip-poolyaml
  namespace: metallb-system
spec:
  addresses:
  - 172.19.155.200-172.19.155.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF
fi



EXPECTED_NODES=$((K8S_MASTER_NODES + K8S_WORKER_NODES))

# Wait until all nodes are in the Ready state
until [[ $(kubectl get nodes --kubeconfig=$TENANTKUBECONFIG | grep -c " Ready ") -eq $EXPECTED_NODES ]]; do
    echo "Waiting for all nodes to become Ready..."
    kubectl get nodes --kubeconfig=$TENANTKUBECONFIG
    sleep 10
done

echo "$(g_echo                     NAVARCOS:INFO:) All nodes are Ready"



export K8S_OIDC_SECRET
yq -i e '.contexts[0].context.user = "oidc" | del(.users[0]) |with(.users[0]; .name = "oidc" | with(.user.exec; .apiVersion = "client.authentication.k8s.io/v1beta1" | .command = "kubectl" | .env = null | .provideClusterInfo = false | .args = ["oidc-login","get-token","--oidc-issuer-url="+strenv(K8S_OIDC_PROVIDER),"--oidc-client-id="+strenv(K8S_TENANT_NAMESPACE)+"-"+strenv(K8S_CLUSTER_NAME)+"-users","--oidc-client-secret="+strenv(K8S_OIDC_SECRET)]))' "$TENANTUSERSKUBECONFIG"
echo "$(g_echo                     NAVARCOS:INFO:) Creating ${K8S_TENANT_NAMESPACE}-(dev|test|prod) namespaces and Bindings"
kubectl apply -f ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.cluster_namespaces_roles.yaml --kubeconfig $TENANTKUBECONFIG

echo "$(g_echo "to access the cluster as ADMIN set the KUBECONFIG variable:")"
echo "$(g_echo "Fish-shell":)"
echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"
echo "$(g_echo "BASH/zsh-shell":) "
echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig"


if [ "$environment" != "kubevirtext" ];then
    
    echo "$(g_echo 'to access the cluster using OIDC set the KUBECONFIG variable, You can create users and associate role on Keycloak: ')"
    echo "Admin:" $(g_echo 'ncadmin@ncadmin.local')
    echo "Password:" $(g_echo 'ncadmin')
    echo "$(g_echo "Fish-shell":)"
    echo "set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"
    echo "$(g_echo "BASH/zsh-shell":)"
    echo "export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}-users.kubeconfig"
    echo "$(g_echo 'to access to Keycloak you need to trust the CA certificate - You cannot ignore this if you plan to connect using OIDC:' )"
    echo "To Install certificate on you local trust store"
    echo $(g_echo "copy/paste the following to create certificate file (bash/zsh)")
    echo "cat <<EOF> kind-navarcos-ca.crt"
    echo "${NAVARCOS_CA}"
    echo "EOF"
    echo $(g_echo "Install on Red Hat based (Centos, Fedora)")
    echo "sudo mv ./kind-navarcos-ca.crt /etc/pki/ca-trust/source/anchors/"
    echo "sudo update-ca-trust"
    echo $(g_echo "Install on Debian based (Ubuntu, Mint)")
    echo "sudo mv ./kind-navarcos-ca.crt /usr/local/share/ca-certificates/"
    echo "sudo update-ca-certificates"
fi

echo "##################### Info Cluster #####################" > ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "##### environment: $environment" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "####### namespace: ${K8S_TENANT_NAMESPACE}" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "########### realm: ${K8S_TENANT_REALM}" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "######### cluster: ${K8S_CLUSTER_NAME}" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "######## keycloak: https://${NAVARCOS_KEYCLOAK_URL}/" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "# keycloack-admin: ncadmin" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "######## bash/zsh: export KUBECONFIG=$(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt
echo "############ fish: set -x KUBECONFIG $(pwd)/bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.kubeconfig" >> ./bootstrap_out/${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}/info-${K8S_TENANT_NAMESPACE}-${K8S_CLUSTER_NAME}.txt




