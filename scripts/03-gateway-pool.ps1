# Step 3: public gateway node pool and WireGuard inbound rule
. "$PSScriptRoot\..\variables.ps1"

$SUBNET_ID = az network vnet subnet show -g $RG --vnet-name aks-vnet -n aks-subnet --query id -o tsv

az aks nodepool add -g $RG --cluster-name $AKS -n pubgw --mode User --node-count 1 --node-vm-size $NODE_SIZE `
  --vnet-subnet-id $SUBNET_ID --enable-node-public-ip --allowed-host-ports 51820-51899/UDP `
  --labels net.unbounded-cloud.io/gateway=aks-public -o none

$NODE_RG = az aks show -g $RG -n $AKS --query nodeResourceGroup -o tsv
$NSG = az network nsg list -g $NODE_RG --query "[0].name" -o tsv
az network nsg rule create -g $NODE_RG --nsg-name $NSG -n AllowUnboundedWireGuard --priority 100 --direction Inbound `
  --access Allow --protocol Udp --source-address-prefixes Internet --source-port-ranges '*' `
  --destination-port-ranges 51820-51899 -o none

kubectl get nodes -l net.unbounded-cloud.io/gateway=aks-public -o wide   # note EXTERNAL-IP
