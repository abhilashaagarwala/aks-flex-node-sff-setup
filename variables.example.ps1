# Copy to variables.ps1 and fill in your values. variables.ps1 is git-ignored.

# Azure
$SUB  = "<subscription-id>"
$RG   = "<resource-group>"            # e.g. rg-aks-flex
$AKS  = "<aks-cluster-name>"          # e.g. aks-flex
$POOL = "<flex-node-pool-name>"       # e.g. flexpool
$LOC  = "eastus"
$K8S_VERSION = "1.36.4"
$NODE_SIZE   = "Standard_D4s_v5"

# Address ranges (must not overlap each other)
$VNET_CIDR    = "10.81.0.0/16"        # AKS VNet
$SUBNET_CIDR  = "10.81.1.0/24"        # AKS node subnet
$AKS_POD_CIDR = "10.83.0.0/16"        # pods on AKS nodes
$SERVICE_CIDR = "10.84.0.0/16"
$DNS_IP       = "10.84.0.10"
$FLEX_LAN_CIDR = "<edge-lan-cidr>"    # LAN the edge machine sits on, e.g. 192.168.1.0/24
$FLEX_POD_CIDR = "10.85.0.0/16"       # pods on Flex nodes

# Edge machine (Arc-enabled server that becomes the Flex node)
$ARC_RG        = "<arc-machine-resource-group>"
$ARC_NAME      = "<arc-machine-name>"
$ARC_PRINCIPAL = "<arc-machine-managed-identity-object-id>"   # az connectedmachine show -g $ARC_RG -n $ARC_NAME --query identity.principalId -o tsv
$SSH_USER      = "<local-user>"                               # e.g. clouduser
$SSH_KEY       = "<path-to-private-key.pem>"
$FLEX_NODE     = "<flex-node-name-in-kubernetes>"             # lowercase hostname of the edge machine
