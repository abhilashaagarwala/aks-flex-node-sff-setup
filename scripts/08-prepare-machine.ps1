# Step 8: enable Arc SSH on the edge machine, then run machine/prepare.sh on it
. "$PSScriptRoot\..\variables.ps1"

$ARC = "/subscriptions/$SUB/resourceGroups/$ARC_RG/providers/Microsoft.HybridCompute/machines/$ARC_NAME"
$body = "$env:TEMP\arc-ssh.json"
'{"properties":{"serviceName":"SSH","port":22}}' | Set-Content $body -Encoding ascii
az rest --method put `
  --url "https://management.azure.com$ARC/providers/Microsoft.HybridConnectivity/endpoints/default/serviceConfigurations/SSH?api-version=2023-03-15" `
  --body "@$body" -o none

Start-Sleep 90   # Arc SSH takes ~30-90 s to start working

Get-Content "$PSScriptRoot\..\machine\prepare.sh" -Raw |
  az ssh arc --resource-id $ARC --local-user $SSH_USER --private-key-file $SSH_KEY -- "FLEX_LAN_CIDR=$FLEX_LAN_CIDR bash -s"
