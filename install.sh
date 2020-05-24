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
set +x # don't print credentials
CREDENTIALS=$3
set -x

KUBERNETES_VERSION="1.16.9"
KUBECTL_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
CROSSPLANE_VERSION="0.11.0"

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

# Install crossplane CLI - https://crossplane.io/docs/v0.11/getting-started/install-configure.html
curl -sL https://raw.githubusercontent.com/crossplane/crossplane-cli/master/bootstrap.sh | sudo bash

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

# Install Crossplane with Azure Provider - https://crossplane.io/docs/v0.11/getting-started/install-configure.html
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: crossplane-system
EOF

helm repo add crossplane-alpha https://charts.crossplane.io/alpha
helm install crossplane crossplane-alpha/crossplane \
  --namespace crossplane-system \
  --version "$CROSSPLANE_VERSION" \
  --wait

kubectl crossplane package install --cluster --namespace crossplane-system crossplane/provider-azure:v0.10.0 provider-azure

# There's a timing issue here where the CRDs installed by the previous step haven't shown up yet.
ELAPSED=0
while [[ $ELAPSED -lt 60 && -z $(kubectl api-resources -o name | awk '/providers.azure.crossplane.io/{print}') ]]
do
    echo "waiting for CRD 'providers.azure.crossplane.io' to appear"
    sleep 3
    ((ELAPSED+=3))
done
if [[ $ELAPSED -ge 60 ]]
then
  echo "timed out waiting for CRD 'providers.azure.crossplane.io' to appear"
  exit 1
fi
unset ELAPSED

# Configure Crossplane with Azure credentials - https://crossplane.github.io/docs/v0.10/cloud-providers/azure/azure-provider.html
set +x # don't print credentials
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: azure-account-creds
  namespace: crossplane-system
type: Opaque
data:
  credentials: ${CREDENTIALS}
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
set -x

# Verify that the provider initialized successfully
ELAPSED=0
while [[ $ELAPSED -lt 180 && "True" != "$(kubectl get clusterpackageinstall provider-azure -n crossplane-system -o jsonpath='{.status.conditionedStatus.conditions[?(.type=="Ready")].status}')" ]]
do
  echo "waiting for provider-azure to start"
  sleep 3
  ((ELAPSED+=3))
done
if [[ $ELAPSED -ge 180 ]]
then
  echo "timed out waiting for provider-azure to start"
  exit 1
fi
unset ELAPSED

# Install the remote addon
kubectl apply -f - <<EOF
apiVersion: packages.crossplane.io/v1alpha1
kind: ClusterPackageInstall
metadata:
  name: addon-oam-kubernetes-remote
  namespace: crossplane-system
spec:
  package: "crossplane/addon-oam-kubernetes-remote:master"
EOF

# Verify that the remote addon started successfully
ELAPSED=0
while [[ $ELAPSED -lt 180 && "1" -gt "$(kubectl get deployment addon-oam-kubernetes-remote-controller --namespace crossplane-system -o jsonpath='{.status.readyReplicas}' || echo "0")" ]]
do
  echo "waiting for addon-oam-kubernetes-remote-controller to start"
  sleep 3
  ((ELAPSED+=3))
done
if [[ $ELAPSED -ge 180 ]]
then
  echo "timed out waiting for addon-oam-kubernetes-remote-controller to start"
  exit 1
fi
unset ELAPSED

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
  version: ${KUBERNETES_VERSION}
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

# Now create the cluster
kubectl apply -f - <<EOF
apiVersion: compute.crossplane.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: k8scluster
spec:
  writeConnectionSecretToRef:
    name: k8scluster
EOF

# Verify cluster is created and accessible to crossplane 20m => 1200s
ELAPSED=0
while [[ $ELAPSED -lt 1200 && "Bound" != "$(kubectl get akscluster -A -o jsonpath='{.items[*].status.bindingPhase}')" ]]
do
  echo "waiting for kubernetes cluster to start"
  sleep 20
  ((ELAPSED+=20))
done
if [[ $ELAPSED -ge 1200 ]]
then
  echo "timed out waiting for kubernetes cluster to start"

  # The events of the akscluster will show any provisioning errors
  kubectl describe akscluster -A
  exit 1
fi
unset ELAPSED

echo "Kubernetes cluster created: $(kubectl get akscluster -A -o jsonpath='{.items[*].metadata.annotations.crossplane\.io/external-name}')"