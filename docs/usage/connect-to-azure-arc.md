---
title: Azure Arc enabled Kubernetes
weight: 70
---

With Azure Arc enabled Kubernetes you can connect your on-prem Kubernetes cluster to manage it from Azure.

## Connecting the Lokomotive cluster

On the management node, run the Azure CLI in a container while giving it access to the home directory of the `core` user:

```
docker run --rm -it --net host -v $HOME:/root mcr.microsoft.com/azure-cli
```

Inside the container, run the following steps to connect the cluster to Azure Arc:

```
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
az extension add --name connectedk8s
az login  # beware: this stores creds in /home/core/.azure/ - you can also use --service-principal -u ID -p PW --tenant ID
# To know the right command arguments, you can follow https://portal.azure.com/#create/Microsoft.ConnectedCluster (choose "bash script"):
az account set --subscription Your-code
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation
az connectedk8s connect --name Your-name --resource-group Your-resource-group --location Your-location
```

Refer to the [Azure Arc quickstart guide](https://docs.microsoft.com/en-us/azure/azure-arc/kubernetes/quickstart-connect-cluster) for up-to-date instructions.
