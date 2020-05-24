#!/usr/bin/env bash
set -e

if [[ -z "$RESOURCE_GROUP" ]]
then
  echo "RESOURCE_GROUP must be set"
  exit 1
fi

if [[ -z "$LOCATION" ]]
then
  echo "LOCATION must be set"
  exit 1
fi

if [[ -z "$VM_NAME" ]]
then
  VM_NAME="rynowak-vm-$RANDOM"
fi

__DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -u
az group create --name "$RESOURCE_GROUP" --location $LOCATION
bash "$__DIR/createvm.sh" "$RESOURCE_GROUP" "$VM_NAME"
IP=$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q "$__DIR/install.sh" "azureuser@$IP:/home/azureuser/install.sh"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q ./crossplane-azure-provider-key.json "azureuser@$IP:/home/azureuser/creds.json"

echo "ready to go at $IP"
echo "ssh azureuser@$IP"
echo "./install.sh \"$RESOURCE_GROUP\" \"$LOCATION\" \"\$(base64 ./creds.json | tr -d '\n')\""