# Navarcos

_Empower Your Cloud Journey with Navarcos: Seamlessly Scalable, Securely Reliable, Effortlessly Powerful._

## Introduction

_Navarcos is an opinionated Kubernetes CaaS/PaaS manager based on ClusterAPI and open source software._

It leverages open source solutions to create and manage a fleet of Kubernetes clusters:

* [Plancia](https://github.com/Navarcos/plancia)

  Is Navarcos' web user interface and backend management service, which enables and orchestrates all the necessary actions to create a Navarcos managed Kubernetes cluster:
  * Creation of the cluster's OIDC client in Keycloak.
  * Configuration and creation of the `Cluster` object in Navarcos' ClusterAPI, enabling the use of OIDC authentication in the managed cluster.
  * Installation of Calico CNI and metrics-server

* [ClusterAPI](https://cluster-api.sigs.k8s.io/)

  Cluster API is a Kubernetes sub-project focused on providing declarative APIs and tooling to simplify provisioning, upgrading, and operating multiple Kubernetes clusters.
  Navarcos uses it to create and manage Kubernetes clusters in IaaS environments.

* [Keycloak](https://www.keycloak.org/)

  Keycloak is an open source software product to allow single sign-on with identity and access management aimed at modern applications and services.
  Navarcos uses it to provide authentication and access management to Kubernetes clusters and its own interface, Plancia.

* [Tigera Operator / Calico Networking](https://www.tigera.io/tigera-products/calico/)

  Calico is an open-source networking and security solution for containers, virtual machines, and native host-based workloads.
  Navarcos uses it as Kubernetes' networking stack, as such offering a a consistent experience and set of capabilities whether running in public cloud or on-premises, or on a single node or across a multi node cluster.

* [Ingress NGINX](https://github.com/kubernetes/ingress-nginx)

  Ingress-nginx is an Ingress controller for Kubernetes using NGINX as a reverse proxy and load balancer.
  Navarcos uses it as Kubernetes default Ingress controller to be compatible with the majority of Helm Charts and standard annotations.

We use the same technologies and processes for our software engineering that we recommend.

This environment supports the entire lifecycle of the platform, from its creation to its maintenance.

By using the same technologies and methodologies recommended to clients, Navarcos ensures consistency and cohesion between the development of the PaaS and the recommended practices.

This homogeneous approach allows developers to work in a familiar and optimized environment, reducing the time and effort required to implement and manage the PaaS.

Navarcos offers a robust and flexible infrastructure designed to support the dynamic needs of cloud-based applications. This ecosystem provides tools and resources to automate complex processes, ensuring efficiency and scalability.

Thanks to its modular nature, Navarcos can be adapted and extended to meet the specific needs of various applications and industrial sectors.

## Table of Contents

[[_TOC_]]

## Pre-requisites

All you need is a system with:

* Docker Engine (https://docs.docker.com/engine/install/)
* kubectl (https://kubernetes.io/docs/tasks/tools/)
* clusterctl (https://github.com/kubernetes-sigs/cluster-api)
* helm (https://helm.sh/)
* jq (https://jqlang.github.io/jq/)
* yq (https://github.com/mikefarah/yq), minimum required version 4.0
* kind (https://kind.sigs.k8s.io/)

Docker Engine is better [installed using your distro's packages](https://docs.docker.com/engine/install/).
All other software can be installed using [homebrew](https://brew.sh/).

## Quick Start (local test environment)

This script automates the local deployment of:

* a management Kind Kubernetes cluster
* a ClusterAPI managed Kubernetes cluster in Docker
* the Plancia webUI and backend management service

and installs necessary Helm charts for components:

* Tigera Operator / Calico CNI
* metrics-server
* cert-manager
* ClusterAPI
  * vSphere Provider
  * Docker Provider
  * IPAM
* Ingress NGINX
* Keycloak

The end result is a local `navarcos` Kind cluster (the management cluster) and a `skafos-docker` managed cluster.

The Plancia webUI and managed clusters are authenticated via OIDC using Navarcos' Keycloak, which can be reached at `https://keycloak.<IP ADDRESS OF CONTROL PLANE NODE>.nip.io/` (the actual FQDN can be retrieved in cluster via `kubectl get node navarcos-control-plane -o jsonpath='{.status.addresses[0].address}'`).
Default administrator credentials are `ncadmin@ncadmin.local`:`ncadmin`.

Files rendered from templates during the installation (e.g. Navarcos values YAML, Keycloak Chart values YAML, Keycloak Realm JSONs) are stored in `./bootstrap_out` for future reference.

Follow these steps to quickly set up a Navarcos test environment using Kind and the ClusterAPI Docker Provider:

1. **Clone the repository**

    ```bash
    git clone https://github.com/navarcos/navarcos.git
    cd navarcos
    ```

2. **Run the bootstrap script**

    Execute the bootstrap script

    ```bash
    ./bootstrap_local_kind.sh
    ```

    to initiate the setup process.
    This script automates the local deployment of the Navarcos management cluster, which hosts Keycloak and ClusterAPI.

3. **Install Plancia**

    Follow instructions from [Plancia's repo](https://github.com/Navarcos/plancia):

    1. Clone Plancia:

       ```bash
       git clone https://github.com/Navarcos/plancia.git
       cd plancia
       ```

    2. Run `deploy.sh` in Plancia directory
    3. Accept Navarcos' CA, either:
       1. Copying the CA Certificate from the script output in a file and installing it in your browser
       2. Connecting and accepting the certificates to:

          * `https://keycloak.<IP ADDRESS OF NAVARCOS CONTROL PLANE>.nip.io`
          * `https://plancia-api.<IP ADDRESS OF NAVARCOS CONTROL PLANE>.nip.io`
          * `https://plancia.<IP ADDRESS OF NAVARCOS CONTROL PLANE>.nip.io`

       Correct URLs are printed during the deploy script.

4. **Create a managed Kubernetes cluster in Plancia**

    Login to Plancia `https://plancia.<IP ADDRESS OF NAVARCOS CONTROL PLANE>.nip.io` with default administrator credentials:

    * username: `ncadmin@ncadmin.local`
    * password: `ncadmin`

    Use Plancia to create a managed Kubernetes cluster using the Docker provider.

5. **(_Alternative_) Create a test managed Kubernetes cluster without Plancia**

    Ensure that the local machine kernel parameters are compatible with the Docker ClusterAPI Provider:

    * `sysctl -b fs.inotify.max_user_watches` must be equal or greater than 1048576
    * `sysctl -b fs.inotify.max_user_instances` must be equal or greater than 8192

    if it is not so:

    * `sudo sysctl fs.inotify.max_user_watches=1048576`
    * `sudo sysctl fs.inotify.max_user_instances=8192`

    Then execute the cluster creation script

    ```bash
    ./create_docker_cluster.sh
    ```

    to create a local cluster using ClusterAPI Docker Provider.

    The created cluster will be called `skafos-docker` and its kubeconfig can be retrieved from the kind-navarcos management cluster:

    ```bash
    kubectl get secret skafos-docker-kubeconfig -n skafos
    ```

    and is saved as `./bootstrap_out/skafos-docker.kubeconfig`.
    Nodes are configured to authenticate via OIDC with the "Skafos" realm `https://keycloak.<IP ADDRESS OF CONTROL PLANE NODE>.nip.io/admin/Skafos/console/`.
    A default user `ncadmin@ncadmin.local` is already setup as cluster administrator with temporary password `ncadmin`.
    A kubeconfig using OIDC authentication is available in `./bootstrap_out/skafos-docker-users.kubeconfig`; it uses the [kubelogin kubectl plugin](https://github.com/int128/kubelogin) for Kubernetes OpenID Connect (OIDC) authentication.

## Bootstrap Workflow

The bootstrap script automates the setup and configuration of the Navarcos environment using Kubernetes and Helm charts. Below is a summary of the workflow:

1. Prerequisites Check: Verifying the presence of essential command-line tools required for deployment.
2. Kind Cluster Existence Check: Verifying if the Kind cluster "kind-navarcos" already exists.
3. Cluster Handling: Depending on the cluster's existence:
    * Delete the cluster if requested (_d_ option).
    * Reuse the existing cluster (_r_ option).
    * Update values and exit (_x_ option).
4. Create Kind Cluster: Creating a new Kind cluster "kind-navarcos" if not reusing an existing one.
5. Obtaining Cluster Domain: Fetching the Navarcos Kind Ingress IP address for service access.
6. Kubernetes Operations:
    * Waiting for kube-scheduler readiness.
    * Installing Tigera/Calico Operator, metrics-server, and cert-manager using Helm charts.
    * Creating self-signed cert-manager ClusterIssuer.
7. ClusterAPI Initialization: Initializing ClusterAPI components and providers.
8. Ingress NGINX Installation: Deploying Ingress NGINX controller.
9. Keycloak Deployment: Installing Keycloak with configurations retrieved from rendered keycloak.values.yaml.
10. Plancia Environment Setup: Creating the plancia namespace and applying configuration maps (plancia.configmaps.yaml) with services URLs.
11. Keycloak Integration:
    * Creating a client (plancia) in the Keycloak master realm with necessary roles.
    * Creating a "Navarcos" realm and clients for Plancia and future services.
12. Storing Secrets: Storing generated client secrets in values.yaml for future reference.

## Version Compatibility

|Component|K8s versions|Software versions|
|---|---|---|
|ClusterAPI v1.6.3|Management Cluster: v1.25.x -> v1.29.x|Cert-Manager: v1.14.2|
||Workload Clusters: v1.23.x -> v1.29.x||
|ClusterAPI Docker v1.6.3||CAPI: v1.6.x|
|ClusterAPI vSphere v1.9.3||CAPI: v1.6.x|
|ClusterAPI IPAM v0.1.0||CAPI: v1.6.x|
|Cert-Manager v1.14.2|v1.24.x -> v1.29.x||
|Calico Tigera v3.26.4|v1.24.x -> v1.28.x||

* <https://github.com/kubernetes-sigs/cluster-api>
* <https://github.com/kubernetes-sigs/cluster-api-provider-vsphere>
* <https://github.com/kubernetes-sigs/cluster-api-ipam-provider-in-cluster>
* <https://cert-manager.io/>
* <https://www.tigera.io/tigera-products/calico/>

## Contributing

Instructions on how to contribute to the project:

* Fork the repository
* Create a new branch (git checkout -b feature/amazing-feature)

```bash
  git checkout -b feature/amazing-feature
```

* Commit your changes (git commit -m 'feat: add amazing-feature')

```bash
  git commit -m 'feat: add amazing-feature'
```

* Push to the branch (git push origin feature/amazing-feature)

```bash
  git push origin feature/amazing-feature
```

* Open a Pull Request

## License

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
You may obtain a copy of the License at

* LICENSE
* <http://www.apache.org/licenses/LICENSE-2.0>

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

## Copyright

Copyright :copyright: 2024 [Activa Digital](https://www.activadigital.it).
