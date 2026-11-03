# Step 6: Unbounded-Net sites, gateway pool and assignments
. "$PSScriptRoot\..\variables.ps1"

@"
apiVersion: unbounded-cloud.io/v1alpha3
kind: Site
metadata: {name: aks-site}
spec: {nodeCidrs: [$VNET_CIDR], podCidrAssignments: [{assignmentEnabled: true, cidrBlocks: [$AKS_POD_CIDR]}], manageCniPlugin: true}
---
apiVersion: unbounded-cloud.io/v1alpha3
kind: Site
metadata: {name: flex-site}
spec: {nodeCidrs: [$FLEX_LAN_CIDR], podCidrAssignments: [{assignmentEnabled: true, cidrBlocks: [$FLEX_POD_CIDR]}], manageCniPlugin: true}
---
apiVersion: net.unbounded-cloud.io/v1alpha1
kind: GatewayPool
metadata: {name: aks-gw}
spec: {type: External, nodeSelector: {net.unbounded-cloud.io/gateway: aks-public}, tunnelProtocol: WireGuard}
---
apiVersion: net.unbounded-cloud.io/v1alpha1
kind: SiteGatewayPoolAssignment
metadata: {name: aks-gw-assignment}
spec: {sites: [aks-site], gatewayPools: [aks-gw], tunnelProtocol: WireGuard}
---
apiVersion: net.unbounded-cloud.io/v1alpha1
kind: SiteGatewayPoolAssignment
metadata: {name: flex-gw-assignment}
spec: {sites: [flex-site], gatewayPools: [aks-gw], tunnelProtocol: WireGuard}
"@ | kubectl apply -f -

kubectl -n unbounded-system rollout status ds/unbounded-net-node --timeout=5m
kubectl get nodes -L unbounded-cloud.io/site   # AKS nodes Ready, in aks-site
