# Step 2: AKS cluster with no CNI (Unbounded-Net provides networking in step 6)
. "$PSScriptRoot\..\variables.ps1"

$SUBNET_ID = az network vnet subnet show -g $RG --vnet-name aks-vnet -n aks-subnet --query id -o tsv

az aks create -g $RG -n $AKS -l $LOC --kubernetes-version $K8S_VERSION `
  --vnet-subnet-id $SUBNET_ID --network-plugin none `
  --pod-cidr $AKS_POD_CIDR --service-cidr $SERVICE_CIDR --dns-service-ip $DNS_IP `
  --nodepool-name nodepool1 --node-count 1 --node-vm-size $NODE_SIZE `
  --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys -o none

az aks get-credentials -g $RG -n $AKS --admin --overwrite-existing
# Nodes stay NotReady until step 6. That's expected.
