# AKS Flex node on an edge machine (SFF) with Unbounded-Net

Scripts to create an AKS cluster with no CNI, connect it to an on-premises Arc-enabled edge machine as a **Flex node**, and network the two sites with [Unbounded-Net](https://github.com/Azure/unbounded) over a WireGuard gateway.

```
 Azure VNet (aks-site)                          Edge LAN (flex-site)
 nodepool1 ── pubgw (public IP, WireGuard) <──── edge machine (Flex node)
 pods: AKS_POD_CIDR                              pods: FLEX_POD_CIDR
```

## Prerequisites
- Azure CLI, `kubectl`, PowerShell 7 on Windows; WSL or Linux for step 5
- Preview features `Microsoft.ContainerService/AKSFlexNodePreview` and `PutMachinePreview` registered
- An Azure Linux edge machine that is Arc-enabled, with an SSH key for a local sudo user
- Quota for two `Standard_D4s_v5` VMs (8 vCPUs) in the region

## Setup
```powershell
Copy-Item variables.example.ps1 variables.ps1   # then fill in your values
```
`variables.ps1` is git-ignored.

## Steps

| # | Where | Script | What it does |
|---|---|---|---|
| 1 | PowerShell | `scripts/01-rg-vnet.ps1` | Resource group and VNet |
| 2 | PowerShell | `scripts/02-aks-cluster.ps1` | AKS cluster with `--network-plugin none`, admin credentials |
| 3 | PowerShell | `scripts/03-gateway-pool.ps1` | `pubgw` pool with public IPs, NSG rule for UDP 51820–51899 |
| 4 | Portal or PowerShell | `scripts/04-flex-pool.ps1` | Flex node pool |
| 5 | WSL / Linux | `scripts/05-install-unbounded.sh` | Installs Unbounded-Net |
| 6 | PowerShell | `scripts/06-sites.ps1` | `aks-site`, `flex-site`, gateway pool and assignments |
| 7 | PowerShell | `scripts/07-rbac.ps1` | Flex Node Agent Role for the machine's Arc identity on the resource group |
| 8 | PowerShell → machine | `scripts/08-prepare-machine.ps1` | Enables Arc SSH, runs `machine/prepare.sh` (packages + firewall) |
| 9 | Portal → machine | — | Add the machine to the Flex pool, then run the onboarding script it gives you (see below) |
| 10 | Machine | `machine/prepare.sh` | Re-run after the node joins if `FORWARD` reset to `DROP` |
| 11 | PowerShell | `scripts/11-verify.ps1` | Node is Ready in `flex-site`, pods running |

Step 5 example from WSL:
```bash
WIN_KUBECONFIG=/mnt/c/Users/<you>/.kube/config KUBE_CONTEXT=<aks-cluster-name>-admin ./scripts/05-install-unbounded.sh
```

### Step 9: onboard the machine
In the portal, add the machine to the Flex pool using Arc sign-in. Save the script it provides as `/tmp/onboard.sh` on the machine and run it **without the Arc proxy**:
```bash
sudo env -u HTTPS_PROXY -u https_proxy bash /tmp/onboard.sh
systemctl is-active aks-flex-node-agent    # expect: active
```

## Address ranges
None of these may overlap.

| Variable | Default | Used for |
|---|---|---|
| `VNET_CIDR` | 10.81.0.0/16 | AKS VNet; `aks-site` node range |
| `AKS_POD_CIDR` | 10.83.0.0/16 | Pods on AKS nodes |
| `SERVICE_CIDR` | 10.84.0.0/16 | Kubernetes services |
| `FLEX_LAN_CIDR` | *your LAN* | `flex-site` node range; must contain the edge machine's IP |
| `FLEX_POD_CIDR` | 10.85.0.0/16 | Pods on Flex nodes |

Unbounded-Net puts each node in the site whose `nodeCidrs` contains the node's internal IP, and gives each node a /24 from that site's pod range.

## Notes
- **Firewall changes are not persistent.** Add them to `/etc/sysconfig/iptables` to survive a reboot.
- **UDP 6081 (GENEVE)** must be allowed between Flex nodes on the same LAN if the machine's INPUT policy is `DROP`.
- Monitoring, Defender, Istio and Gateway API are left out; add them later with `az aks update`.
- The resource-group-scoped role in step 7 covers any Flex pool in the cluster. Scope it to `.../agentPools/<pool>` for least privilege.
