#!/usr/bin/env bash
set -eux

if [[ "$#" -ne 3 ]]
then
  echo "usage: install.sh <resource-group> <location> <credentials>"
  echo 'ex:    CREDS=$(base64 crossplane-azure-provider-key.json | tr -d "\n")'
  echo 'ex:    install.sh my-resource-group eastus2 "$CREDS"'
  exit 1
fi

RESOURCE_GROUP=$1
LOCATION=$2
CREDENTIALS=$3

KUBECTL_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
CROSSPLANE_VERSION="0.10.0"

# verify virtualization support: we need a vmx for virtual box
output=$(grep -E --color 'vmx|svm' /proc/cpuinfo)
if [[ -z $output ]]
then
    echo "Virtualization support is required. Make sure you created a VM with size Standard_D4s_v3 (or larger)."
    exit 1
fi

# Install virtual box
sudo apt-get update
sudo apt-get install -y virtualbox

# Install kubectl - https://kubernetes.io/docs/tasks/tools/install-kubectl/#install-kubectl-on-linux
curl -LO "https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
kubectl version --client

# Install helm - https://helm.sh/docs/intro/install/
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm version

# Install minikube - https://kubernetes.io/docs/tasks/tools/install-minikube/
curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
chmod +x ./minikube
sudo mv ./minikube /usr/local/bin/minikube
minikube version

# Launch minikube and stop on exit
minikube start
function cleanup {
  minikube stop
}
trap cleanup EXIT

# Install Crossplane with Azure Provider - https://crossplane.github.io/docs/v0.10/getting-started/install.html
kubectl create namespace crossplane-system
helm repo add crossplane-alpha https://charts.crossplane.io/alpha
helm install crossplane crossplane-alpha/crossplane \
  --namespace crossplane-system \
  --set clusterStacks.azure.deploy=true \
  --version "$CROSSPLANE_VERSION" \
  --wait

# There's a timing issue here where the CRDs installed by the previous step haven't shown up yet.
while [[ -z $(kubectl api-resources -o name | awk '/providers.azure.crossplane.io/{print}') ]]
do
    echo "waiting for CRD 'providers.azure.crossplane.io' to appear"
    sleep 3
done

# Configure Crossplane with Azure credentials - https://crossplane.github.io/docs/v0.10/cloud-providers/azure/azure-provider.html
BASE64ENCODED_AZURE_ACCOUNT_CREDS=$(base64 creds.json | tr -d "\n")
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: azure-account-creds
  namespace: crossplane-system
type: Opaque
data:
  credentials: ${BASE64ENCODED_AZURE_ACCOUNT_CREDS}
---
apiVersion: azure.crossplane.io/v1alpha3
kind: Provider
metadata:
  name: azure-provider
spec:
  credentialsSecretRef:
    namespace: crossplane-system
    name: azure-account-creds
    key: credentials
EOF
unset BASE64ENCODED_AZURE_ACCOUNT_CREDS

# Install the remote addon
kubectl apply -f - <<EOF
apiVersion: stacks.crossplane.io/v1alpha1
kind: ClusterStackInstall
metadata:
  name: addon-oam-kubernetes-remote
  namespace: crossplane-system
spec:
  package: "crossplane/addon-oam-kubernetes-remote:master"
EOF

# Define a resource-group
kubectl apply -f - <<EOF
apiVersion: azure.crossplane.io/v1alpha3
kind: ResourceGroup
metadata:
  name: ${RESOURCE_GROUP}
spec:
  location: ${LOCATION}
  reclaimPolicy: Retain
  providerRef:
    name: azure-provider
EOF

# Define class for AKS clusters - https://crossplane.io/docs/v0.4/stacks-guide-azure.html
# This is just a template, and won't create a cluster directly
kubectl apply -f - <<EOF
apiVersion: compute.azure.crossplane.io/v1alpha3
kind: AKSClusterClass
metadata:
  name: standard-cluster
  annotations:
    resourceclass.crossplane.io/is-default-class: "true"
specTemplate:
  writeConnectionSecretsToNamespace: crossplane-system
  resourceGroupNameRef:
    name: ${RESOURCE_GROUP}
  location: ${LOCATION}
  version: "1.16.7"
  nodeCount: 1
  nodeVMSize: Standard_D4s_v3
  dnsNamePrefix: crossplane-aks
  disableRBAC: false
  writeServicePrincipalTo:
    name: akscluster-net
    namespace: crossplane-system
  reclaimPolicy: Delete
  providerRef:
    name: azure-provider
EOF

kubectl apply -f - <<EOF
apiVersion: compute.crossplane.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: k8scluster
spec:
  writeConnectionSecretToRef:
    name: k8scluster
EOF

