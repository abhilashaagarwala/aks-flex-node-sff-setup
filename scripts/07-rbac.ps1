# Step 7: give the edge machine's Arc identity the Flex Node Agent Role on the resource group
. "$PSScriptRoot\..\variables.ps1"

$FLEX_AGENT_ROLE = "8f139b0f-7eaf-460b-a9da-5b1246d9ed0d"   # Azure Kubernetes Service Flex Node Agent Role

az role assignment create --assignee-object-id $ARC_PRINCIPAL --assignee-principal-type ServicePrincipal `
  --role $FLEX_AGENT_ROLE --scope "/subscriptions/$SUB/resourceGroups/$RG" -o none
