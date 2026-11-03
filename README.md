# AKS Flex Node on an Azure Local small form factor device

Join an Azure Local small form factor (SFF) device to a cloud-hosted AKS cluster as a **Flex node**, using Unbounded-Net and a WireGuard gateway to connect the device's on-premises network to Azure.

## Overview

[AKS Flex Node](https://github.com/Azure/AKSFlexNode) lets you connect a machine running anywhere to an AKS cluster as a node. The AKS control plane stays in Azure, and the machine runs your workloads where they're needed. The upstream project publishes [hands-on labs](https://github.com/Azure/AKSFlexNode/blob/main/docs/labs/README.md) for these scenarios. This guide follows the **[Public AKS cluster with an Unbounded-Net WireGuard Flex node](https://github.com/Azure/AKSFlexNode/blob/main/docs/labs/aks-public-cluster-unbounded-net-wireguard.md)** lab, which needs no VNet peering. In that lab the Flex node is an Azure VM. Here, the Flex node is a physical edge device.

[Small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2606) run Azure Local on compact, Linux-based hardware for retail stores, factories, and other edge sites, managed through Azure Arc. SFF devices can already run Kubernetes locally with AKS or K3s. This guide shows a different option: keep the control plane in Azure and attach the device to an AKS cluster as a Flex node, so you manage cloud and edge nodes from one cluster.

### What you'll build

```
 Azure VNet (aks-site)                            On-premises LAN (flex-site)
 ┌───────────────────────────────┐                ┌──────────────────────────────┐
 │ nodepool1   (system)          │                │ SFF provisioned machine      │
 │ pubgw       (public IP,       │◄── WireGuard ──│ (Arc-enabled, Flex node)     │
 │              WireGuard gw)    │    UDP 51820+  │                              │
 │ pods: 10.83.0.0/16            │                │ pods: 10.85.0.0/16           │
 └───────────────────────────────┘                └──────────────────────────────┘
```

- An AKS cluster created with **no network plugin**, so Unbounded-Net acts as the CNI.
- A `pubgw` node pool with public IPs that serves as the WireGuard gateway.
- Two Unbounded-Net **sites**: `aks-site` for the Azure nodes and `flex-site` for the SFF device's LAN.
- The SFF device joined to the cluster as a Flex node, authenticated through its Azure Arc identity.

> [!IMPORTANT]
> AKS Flex Node and Azure Local small form factor deployments are both in **preview**. Use this setup for evaluation, not production.

**Tested with:** Unbounded-Net `v0.8.0`, Kubernetes `1.36.4`.

## Prerequisites

### SFF provisioned machine

- An Azure Local SFF device that's provisioned, Arc-enabled, and in the **Running** state. See [Prepare to deploy Azure Local on small form factor devices](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2606).
- A local user and SSH private key for the device.

### Azure subscription

- Quota for two `Standard_D4s_v5` VMs (8 vCPUs) in your target region.
- The Flex node preview features registered. Registration can take several minutes. Wait until both show `Registered` before step 3.

  ```powershell
  az feature register --namespace Microsoft.ContainerService --name AKSFlexNodePreview
  az feature register --namespace Microsoft.ContainerService --name PutMachinePreview
  az feature list --query "[?contains(name,'AKSFlexNodePreview') || contains(name,'PutMachinePreview')].{name:name,state:properties.state}" -o table
  az provider register --namespace Microsoft.ContainerService
  ```

### Workstation

- Windows with Azure CLI, `kubectl`, and WSL (Ubuntu).
- WSL is needed because `kubectl-unbounded` has no Windows build.

All commands are PowerShell unless noted otherwise. Run them in **one session** so the variables carry over between steps.

## Step 1: Set variables

Fill in the placeholders for your environment.

```powershell
$SUB="<subscription-id>"
$RG="<resource-group>"
$AKS="<cluster-name>"
$LOC="eastus"
$LAN="<lan-cidr>"                            # LAN the SFF device is on, e.g. 192.168.1.0/24
$ARC_RG="<arc-machine-resource-group>"
$ARC_NAME="<arc-machine-name>"
$SSH_USER="<local-user>"
$SSH_KEY="<path-to-private-key.pem>"
$ARC="/subscriptions/$SUB/resourceGroups/$ARC_RG/providers/Microsoft.HybridCompute/machines/$ARC_NAME"
$SSH = { param($cmd) az ssh arc -g $ARC_RG -n $ARC_NAME --local-user $SSH_USER --private-key-file $SSH_KEY -- $cmd }
az account set -s $SUB
```

`$SSH` is a helper that runs a command on the device over Arc SSH, so you don't need direct network access to it.

## Step 2: Prepare the SFF device

**Enable SSH through Azure Arc.** It takes 30–90 seconds before connections succeed.

```powershell
az rest --method put --url "https://management.azure.com$ARC/providers/Microsoft.HybridConnectivity/endpoints/default/serviceConfigurations/SSH?api-version=2023-03-15" --body '{\"properties\":{\"serviceName\":\"SSH\",\"port\":22}}'
```

**Install the packages the Flex agent needs.**

```powershell
& $SSH "sudo tdnf install -y nftables systemd-container"
```

**Open the firewall for pod traffic.** This allows forwarding and accepts GENEVE (UDP 6081) traffic from the local LAN.

```powershell
& $SSH "sudo iptables -P FORWARD ACCEPT && sudo iptables -I INPUT 1 -s $LAN -p udp --dport 6081 -m comment --comment 'unbounded GENEVE intra-site' -j ACCEPT"
```

## Step 3: Create the AKS cluster and gateway node pool

This step creates:

1. A resource group and a VNet (`10.81.0.0/16`).
2. An AKS cluster with `--network-plugin none`.
3. A `pubgw` node pool with public node IPs and UDP ports 51820–51899 open, so the SFF device can reach it over WireGuard.

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

> [!NOTE]
> The nodes report `NotReady` until Unbounded-Net is installed in step 4. This is expected because the cluster has no CNI yet.

## Step 4: Install and configure Unbounded-Net

Install the `kubectl-unbounded` plugin in WSL and use it to deploy Unbounded-Net to the cluster with your Windows kubeconfig.

```powershell
wsl -e bash -c "curl -fsSLo /tmp/ku.tgz https://github.com/Azure/unbounded/releases/download/v0.8.0/kubectl-unbounded-linux-amd64.tar.gz && tar -xzf /tmp/ku.tgz -C /tmp && install -D -m 0755 /tmp/kubectl-unbounded ~/bin/kubectl-unbounded"
wsl -e bash -c "KUBECONFIG=/mnt/c/Users/$env:USERNAME/.kube/config ~/bin/kubectl-unbounded install --timeout 5m"
```

Then define the network topology:

| Resource | Purpose |
|---|---|
| `Site` `aks-site` | Azure nodes (`10.81.0.0/16`), pods from `10.83.0.0/16` |
| `Site` `flex-site` | SFF device's LAN (`$LAN`), pods from `10.85.0.0/16` |
| `GatewayPool` `aks-gw` | The `pubgw` nodes, acting as an external WireGuard gateway |
| `SiteGatewayPoolAssignment` × 2 | Attaches both sites to the gateway pool |

```powershell
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
```

Wait for the rollout, then confirm both Azure nodes are `Ready` and in `aks-site`:

```powershell
kubectl -n unbounded-system rollout status ds/unbounded-net-node --timeout=5m
kubectl get nodes -L unbounded-cloud.io/site
```

## Step 5: Grant the device's Arc identity the Flex Node Agent role

The Flex agent on the device authenticates to Azure with the machine's Arc managed identity. Give that identity the **Azure Kubernetes Service Flex Node Agent Role** on the cluster's resource group.

```powershell
az role assignment create --assignee-object-id (az resource show --ids $ARC --query identity.principalId -o tsv) --assignee-principal-type ServicePrincipal --role "Azure Kubernetes Service Flex Node Agent Role" --scope "/subscriptions/$SUB/resourceGroups/$RG"
```

## Step 6: Add the Flex node pool

In the Azure portal, open the AKS cluster and go to **Node pools** > **Add** > **Flex nodes**. Select the SFF device's Arc machine and create the pool.

## Step 7: Verify

Confirm the SFF device is `Ready` and in `flex-site`, and that no pods are stuck:

```powershell
kubectl get nodes -L unbounded-cloud.io/site -o wide
kubectl get pods -A -o wide | Select-String -NotMatch "Running|Completed"   # should print nothing
```

If a pod on the SFF device (for example, `gantry`) stays not-ready, onboarding has reset the device's firewall rules. Rerun the firewall command from step 2.

## Address plan

None of these ranges may overlap.

| Range | Used for |
|---|---|
| `10.81.0.0/16` | AKS VNet; nodes in `aks-site` |
| `10.83.0.0/16` | Pods on AKS nodes |
| `10.84.0.0/16` | Kubernetes services |
| `$LAN` | On-premises LAN; nodes in `flex-site` |
| `10.85.0.0/16` | Pods on Flex nodes |

Unbounded-Net places each node in the site whose `nodeCidrs` contains the node's IP, and assigns each node a `/24` from that site's pod range.

## Considerations

- **Firewall persistence.** The firewall rules from step 2 don't survive a reboot, and joining the node to the cluster resets them (see step 7). To keep them, add them to `/etc/sysconfig/iptables` on the device.
- **GENEVE (UDP 6081).** Carries pod traffic between Flex nodes on the same LAN. The rule matters when the device's `INPUT` policy is `DROP`.
- **Least privilege.** Step 5 grants the role on the whole resource group, so it covers any Flex pool in the cluster. Once the pool exists, you can scope it to `.../managedClusters/<cluster>/agentPools/<pool>` instead.
- **Add-ons.** Monitoring, Defender, Istio, and Gateway API are left out to keep the setup minimal. Add them later with `az aks update`.

## Clean up

Delete the resource group to remove the cluster, VNet, gateway pool, and node resource group:

```powershell
az group delete -n $RG --yes --no-wait
```

The SFF device and its Arc resource live in `$ARC_RG` and aren't affected.

## References

- [AKS Flex Node](https://github.com/Azure/AKSFlexNode) and its [labs](https://github.com/Azure/AKSFlexNode/blob/main/docs/labs/README.md)
- [Upstream lab: Public AKS cluster with an Unbounded-Net WireGuard Flex node](https://github.com/Azure/AKSFlexNode/blob/main/docs/labs/aks-public-cluster-unbounded-net-wireguard.md)
- [Unbounded-Net](https://github.com/Azure/unbounded)
- [What are small form factor deployments of Azure Local (preview)?](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2606)
- [Prepare to deploy Azure Local on small form factor devices](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy?view=azloc-2606)
