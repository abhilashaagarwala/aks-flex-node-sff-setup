# Step 11: check the Flex node joined and its pods are healthy
. "$PSScriptRoot\..\variables.ps1"

kubectl get node $FLEX_NODE -L unbounded-cloud.io/site -o wide            # Ready, flex-site
kubectl get pods -A -o wide --field-selector spec.nodeName=$FLEX_NODE    # all Running
kubectl get sites,gatewaypoolnodes -A
