# AKS Flex node on an edge machine with Unbounded-Net

Steps to create an AKS cluster with no CNI, join an Arc-enabled edge machine to it as a **Flex node**, and connect the two sites with [Unbounded-Net](https://github.com/Azure/unbounded) over a WireGuard gateway.

```
 Azure VNet (aks-site)                          Edge LAN (flex-site)
 nodepool1 ── pubgw (public IP, WireGuard) <──── edge machine (Flex node)
 pods: 10.83.0.0/16                              pods: 10.85.0.0/16
```

## Prerequisites
- Windows with Azure CLI, `kubectl` and WSL (Ubuntu). `kubectl-unbounded` has no Windows build.
- Preview features `AKSFlexNodePreview` and `PutMachinePreview` registered on the subscription.
- An Arc-enabled Azure Linux edge machine, with an SSH key for a local sudo user.
- Quota for two `Standard_D4s_v5` VMs (8 vCPUs).

All commands are PowerShell unless marked otherwise. Run them in one session so the variables carry over.

## 1. Set variables
```powershell
$SUB="<subscription-id>"; $RG="<resource-group>"; $AKS="<cluster-name>"; $LOC="eastus"
$LAN="<edge-lan-cidr>"                       # LAN the edge machine is on, e.g. 192.168.1.0/24
$ARC_RG="<arc-machine-resource-group>"; $ARC_NAME="<arc-machine-name>"
$SSH_USER="<local-user>"; $SSH_KEY="<path-to-private-key.pem>"
$ARC="/subscriptions/$SUB/resourceGroups/$ARC_RG/providers/Microsoft.HybridCompute/machines/$ARC_NAME"
$SSH = { param($cmd) az ssh arc -g $ARC_RG -n $ARC_NAME --local-user $SSH_USER --private-key-file $SSH_KEY -- $cmd }
az account set -s $SUB
```

## 2. Create the cluster and gateway pool
Creates the resource group, the VNet, the cluster with no network plugin, and a `pubgw` pool with public IPs that WireGuard can reach.
```powershell
az group create -n $RG -l $LOC -o none
az network vnet create -g $RG -n aks-vnet -l $LOC --address-prefixes 10.81.0.0/16 --subnet-name aks-subnet --subnet-prefixes 10.81.1.0/24 -o none
$SUBNET_ID = az network vnet subnet show -g $RG --vnet-name aks-vnet -n aks-subnet --query id -o tsv

az aks create -g $RG -n $AKS -l $LOC --kubernetes-version 1.36.4 `
  --vnet-subnet-id $SUBNET_ID --network-plugin none `
  --pod-cidr 10.83.0.0/16 --service-cidr 10.84.0.0/16 --dns-service-ip 10.84.0.10 `
  --nodepool-name nodepool1 --node-count 1 --node-vm-size Standard_D4s_v5 `
  --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys -o none
az aks get-credentials -g $RG -n $AKS --admin --overwrite-existing

az aks nodepool add -g $RG --cluster-name $AKS -n pubgw --mode User --node-count 1 --node-vm-size Standard_D4s_v5 `
  --vnet-subnet-id $SUBNET_ID --enable-node-public-ip --allowed-host-ports 51820-51899/UDP `
  --labels net.unbounded-cloud.io/gateway=aks-public -o none
$NODE_RG = az aks show -g $RG -n $AKS --query nodeResourceGroup -o tsv
$NSG = az network nsg list -g $NODE_RG --query "[0].name" -o tsv
az network nsg rule create -g $NODE_RG --nsg-name $NSG -n AllowUnboundedWireGuard --priority 100 --direction Inbound `
  --access Allow --protocol Udp --source-address-prefixes Internet --source-port-ranges '*' --destination-port-ranges 51820-51899 -o none
```
Nodes show `NotReady` until step 3.

## 3. Set up Unbounded-Net
Installs Unbounded-Net through WSL, using your Windows kubeconfig, then creates the two sites and the gateway.
```powershell
wsl -e bash -c "curl -fsSLo /tmp/ku.tgz https://github.com/Azure/unbounded/releases/download/v0.8.0/kubectl-unbounded-linux-amd64.tar.gz && tar -xzf /tmp/ku.tgz -C /tmp && install -D -m 0755 /tmp/kubectl-unbounded ~/bin/kubectl-unbounded"
wsl -e bash -c "KUBECONFIG=/mnt/c/Users/$env:USERNAME/.kube/config ~/bin/kubectl-unbounded install --timeout 5m"

@"
apiVersion: unbounded-cloud.io/v1alpha3
kind: Site
metadata: {name: aks-site}
spec: {nodeCidrs: [10.81.0.0/16], podCidrAssignments: [{assignmentEnabled: true, cidrBlocks: [10.83.0.0/16]}], manageCniPlugin: true}
---
apiVersion: unbounded-cloud.io/v1alpha3
kind: Site
metadata: {name: flex-site}
spec: {nodeCidrs: [$LAN], podCidrAssignments: [{assignmentEnabled: true, cidrBlocks: [10.85.0.0/16]}], manageCniPlugin: true}
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
kubectl get nodes -L unbounded-cloud.io/site    # both nodes Ready, in aks-site
```

## 4. Give the machine's Arc identity the Flex Node Agent Role
```powershell
az role assignment create --assignee-object-id (az resource show --ids $ARC --query identity.principalId -o tsv) --assignee-principal-type ServicePrincipal --role "Azure Kubernetes Service Flex Node Agent Role" --scope "/subscriptions/$SUB/resourceGroups/$RG"
```

## 5. Enable Arc SSH and prepare the machine
Turn on SSH through Arc (it takes 30–90 seconds to start working):
```powershell
az rest --method put --url "https://management.azure.com$ARC/providers/Microsoft.HybridConnectivity/endpoints/default/serviceConfigurations/SSH?api-version=2023-03-15" --body '{\"properties\":{\"serviceName\":\"SSH\",\"port\":22}}'
```
Install the packages the Flex agent needs:
```powershell
& $SSH "sudo tdnf install -y nftables systemd-container"
```

## 6. Add the machine as a Flex node (portal)
1. In the AKS cluster, go to **Node pools → Add → Flex nodes** and create the pool.
2. Add the edge machine to the pool using Arc sign-in.
3. If the portal gives you an onboarding script instead of running it for you, save it on the machine as `/tmp/onboard.sh` and run it **without the Arc proxy** (on the machine):
   ```bash
   sudo env -u HTTPS_PROXY -u https_proxy bash /tmp/onboard.sh
   ```

## 7. Open the machine's firewall for pod traffic
Do this **after** the node joins. Onboarding resets the firewall to drop forwarded traffic, and pods on the machine (such as `gantry`) stay not-ready until this runs.
```powershell
& $SSH "sudo iptables -P FORWARD ACCEPT && sudo iptables -I INPUT 1 -s $LAN -p udp --dport 6081 -m comment --comment 'unbounded GENEVE intra-site' -j ACCEPT"
```

## 8. Check it works
```powershell
kubectl get nodes -L unbounded-cloud.io/site -o wide                   # edge machine Ready, in flex-site
kubectl get pods -A -o wide | Select-String -NotMatch "Running|Completed"   # nothing listed
```

## Address ranges
None of these may overlap.

| Range | Used for |
|---|---|
| 10.81.0.0/16 | AKS VNet; nodes in `aks-site` |
| 10.83.0.0/16 | Pods on AKS nodes |
| 10.84.0.0/16 | Kubernetes services |
| `$LAN` | Edge LAN; nodes in `flex-site` |
| 10.85.0.0/16 | Pods on Flex nodes |

Unbounded-Net puts each node in the site whose `nodeCidrs` contains the node's IP, and gives each node a /24 from that site's pod range.

## Notes
- **The firewall changes in step 7 don't survive a reboot**, and re-onboarding resets them. Add them to `/etc/sysconfig/iptables` to keep them.
- **UDP 6081 (GENEVE)** carries pod traffic between Flex nodes on the same LAN. The rule matters when the machine's INPUT policy is `DROP`.
- **Step 4 grants the role on the whole resource group**, so it covers any Flex pool in the cluster. For least privilege, scope it to `.../managedClusters/<cluster>/agentPools/<pool>` once the pool exists.
- Monitoring, Defender, Istio and Gateway API are left out. Add them later with `az aks update`.
