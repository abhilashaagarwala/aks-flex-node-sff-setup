# Step 4: Flex node pool
# Portal alternative: AKS cluster > Node pools > Add > Flex nodes.
# Requires preview features AKSFlexNodePreview and PutMachinePreview registered on the subscription.
. "$PSScriptRoot\..\variables.ps1"

az extension add -n aks-preview --version 22.0.0b8 --allow-preview true --upgrade
az aks nodepool add -g $RG --cluster-name $AKS -n $POOL --vm-set-type FlexNodes --mode User `
  --kubernetes-version $K8S_VERSION --max-pods 30
