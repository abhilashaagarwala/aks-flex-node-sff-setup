# Step 1: resource group and VNet
. "$PSScriptRoot\..\variables.ps1"

az account set -s $SUB
az group create -n $RG -l $LOC -o none
az network vnet create -g $RG -n aks-vnet -l $LOC `
  --address-prefixes $VNET_CIDR --subnet-name aks-subnet --subnet-prefixes $SUBNET_CIDR -o none
