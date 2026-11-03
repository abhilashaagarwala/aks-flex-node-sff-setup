#!/usr/bin/env bash
# Step 5: install Unbounded-Net. kubectl-unbounded has no Windows build, so run this in WSL/Linux.
# Usage: KUBE_CONTEXT=<aks-cluster-name>-admin ./05-install-unbounded.sh
set -euo pipefail
: "${KUBE_CONTEXT:?set KUBE_CONTEXT, e.g. aks-flex-admin}"
UNBOUNDED_VERSION="${UNBOUNDED_VERSION:-v0.8.0}"

# Reuse the Windows kubeconfig when running under WSL
if [[ ! -f ~/.kube/config && -n "${WIN_KUBECONFIG:-}" ]]; then
  mkdir -p ~/.kube && cp "$WIN_KUBECONFIG" ~/.kube/config && chmod 600 ~/.kube/config
fi

mkdir -p ~/bin
curl -fsSLo /tmp/ku.tgz "https://github.com/Azure/unbounded/releases/download/${UNBOUNDED_VERSION}/kubectl-unbounded-linux-amd64.tar.gz"
tar -xzf /tmp/ku.tgz -C /tmp && install -m 0755 /tmp/kubectl-unbounded ~/bin/

# Run the plugin directly so this works even without kubectl installed in WSL
sed -i "s/^current-context: .*/current-context: ${KUBE_CONTEXT}/" ~/.kube/config
~/bin/kubectl-unbounded install --timeout 5m
