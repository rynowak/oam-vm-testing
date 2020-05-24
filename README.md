## Running the script

```sh
export RESOURCE_GROUP="..."
export LOCATION="..."
./go.sh
```

Make sure you have `crossplane-azure-provider-key.json` in the working directory. 

This will create an Azure VM for you and then print instructions.

## Running the arm template

```sh
export RESOURCE_GROUP="..."
export LOCATION="..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
az deployment group validate \
  --template-file arm.json \
  --resource-group $RESOURCE_GROUP \
  --parameter "adminPasswordOrKey=$(cat ~/.ssh/id_rsa.pub)" \
  --parameter "servicePrincipal=$(cat crossplane-azure-provider-key.json)"

az deployment group what-if \
  --template-file arm.json \
  --resource-group $RESOURCE_GROUP \
  --parameter "adminPasswordOrKey=$(cat ~/.ssh/id_rsa.pub)" \
  --parameter "servicePrincipal=$(cat crossplane-azure-provider-key.json)"

az deployment group create \
  --template-file arm.json \
  --resource-group $RESOURCE_GROUP \
  --parameter "adminPasswordOrKey=$(cat ~/.ssh/id_rsa.pub)" \
  --parameter "servicePrincipal=$(cat crossplane-azure-provider-key.json)"