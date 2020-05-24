#!/usr/bin/env bash
set -eux

if [[ "$#" -ne 2 ]]
then
  echo "usage: createvm.sh <resource-group> <vm-name>"
  exit 1
fi

RESOURCE_GROUP=$1
VM_NAME=$2

existing=$(az group list --query "[?name=='$RESOURCE_GROUP'].name" -o tsv)
if [[ -z "$existing" ]]
then
    az group create --name $RESOURCE_GROUP --location EastUS2
fi

az vm create \
--resource-group $RESOURCE_GROUP \
  --size Standard_D4s_v3  \
  --name $VM_NAME \
  --image UbuntuLTS \
  --admin-username azureuser \
  --generate-ssh-keys