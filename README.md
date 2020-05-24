## Running the arm template

```sh
RESOURCE_GROUP="..."
az group create --name $RESOURCE_GROUP --location eastus2
az deployment group validate \
  --resource-group $RESOURCE_GROUP \
  --parameter "adminPasswordOrKey=$(cat ~/.ssh/id_rsa.pub)" \