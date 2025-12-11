#!/bin/bash

# This script update an existing AKS to add AGC in order to migrate
# Source: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller?tabs=install-helm-windows
# Source: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/migrate-from-agic-to-agc

# ---------------------------------------------------------------------------- #
#                                  Prequisites                                 #
# ---------------------------------------------------------------------------- #

# Resolve script directory for helper invocations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBNET_HELPER="$SCRIPT_DIR/scripts/compute_non_overlapping_subnet.py"

# Ensure Azure CLI is available (needed for most operations below)
if ! command -v az >/dev/null 2>&1; then
	echo "Azure CLI not found. Installing via Microsoft package..."
	curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

  # Register required resource providers on Azure
  echo "Registering required resource providers on Azure..."
  az provider register --namespace Microsoft.ContainerService
  az provider register --namespace Microsoft.Network
  az provider register --namespace Microsoft.NetworkFunction
  az provider register --namespace Microsoft.ServiceNetworking

  # Install Azure CLI extensions
  echo "Installing required Azure CLI extensions..."
  az extension add --name alb
fi

# Ensure Helm is available for chart installation
if ! command -v helm >/dev/null 2>&1; then
	echo "Helm not found. Installing via official script..."
	curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Ensure kubectl is available for namespace management and verification commands
if ! command -v kubectl >/dev/null 2>&1; then
	echo "kubectl not found. Installing via az aks install-cli..."
	INSTALL_LOCATION="$HOME/.local/bin/kubectl"
	mkdir -p "$(dirname "$INSTALL_LOCATION")"
	if az aks install-cli --install-location "$INSTALL_LOCATION"; then
		chmod +x "$INSTALL_LOCATION"
		export PATH="$HOME/.local/bin:$PATH"
	else
		echo "az aks install-cli failed, attempting direct download..."
		STABLE_KUBECTL_VERSION="$(curl -sL https://dl.k8s.io/release/stable.txt)"
		curl -sL "https://dl.k8s.io/release/${STABLE_KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o "$INSTALL_LOCATION"
		chmod +x "$INSTALL_LOCATION"
		export PATH="$HOME/.local/bin:$PATH"
	fi
	echo "kubectl installed to $INSTALL_LOCATION (PATH updated for this session)"
fi

# ---------------------------------------------------------------------------- #
#                       Update AKS to add AGC Controller                       #
# ---------------------------------------------------------------------------- #

AKS_NAME='aks-with-nginx'
RESOURCE_GROUP_NAME='rg-aks-with-nginx'
LOCATION='germanywestcentral'
VM_SIZE='Standard_D2as_v5' # The size needs to be available in your location

# Update the cluster to support workload identities
az aks update -g $RESOURCE_GROUP_NAME -n $AKS_NAME --enable-oidc-issuer --enable-workload-identity

# ---------------------------------------------------------------------------- #
#                        Install ALB Controller via Helm                       #
# ---------------------------------------------------------------------------- #


# -------------------- Managed Idenity for ALB Controller -------------------- #

# First Create a user managed identity for ALB controller and federate the identity as Workload Identity to use in the AKS cluster.

# ALB Controller requires a federated credential with the name of azure-alb-identity. Any other federated credential name is unsupported.
IDENTITY_RESOURCE_NAME='azure-alb-identity'

# Get AKS managed cluster resource group
mcResourceGroupName=$(az aks show --resource-group "$RESOURCE_GROUP_NAME" --name "$AKS_NAME" --query "nodeResourceGroup" -o tsv)
mcResourceGroupId=$(az group show --name $mcResourceGroupName --query id -o tsv)

# Create user managed identity
echo "Creating identity $IDENTITY_RESOURCE_NAME in resource group $RESOURCE_GROUP_NAME"
az identity create --resource-group "$RESOURCE_GROUP_NAME" --name "$IDENTITY_RESOURCE_NAME"
principalId="$(az identity show -g "$RESOURCE_GROUP_NAME" -n "$IDENTITY_RESOURCE_NAME" --query principalId -o tsv)"

# Wait for identity replication
echo "Waiting 60 seconds to allow for replication of the identity..."
sleep 60

# Assign Reader role to the AKS managed cluster resource group for the newly provisioned identity
echo "Apply Reader role to the AKS managed cluster resource group for the newly provisioned identity"
az role assignment create \
	--assignee-object-id "$principalId" \
	--assignee-principal-type ServicePrincipal \
	--scope "$mcResourceGroupId" \
	--role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

# ---------------------- Federate Identity with AKS OIDC --------------------- #

# Get AKS OIDC issuer URL
echo "Set up federation with AKS OIDC issuer"
AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)"

# Create federated credential for the managed identity
az identity federated-credential create \
	--name "azure-alb-identity" \
	--identity-name "$IDENTITY_RESOURCE_NAME" \
	--resource-group "$RESOURCE_GROUP_NAME" \
	--issuer "$AKS_OIDC_ISSUER" \
	--subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

# ---------------------- Install ALB Controller via Helm --------------------- #

# Helm best practice: dedicate a namespace per chart/release (matching release name)
HELM_NAMESPACE='azure-alb-system-helm'
# ALB controller pods remain in the vendor-owned namespace as required by the chart
CONTROLLER_NAMESPACE='azure-alb-system'

# Get AKS credentials
az aks get-credentials --resource-group "$RESOURCE_GROUP_NAME" --name "$AKS_NAME"

# Ensure the Helm target namespace exists
if ! kubectl get namespace "$HELM_NAMESPACE" >/dev/null 2>&1; then
	echo "Creating namespace $HELM_NAMESPACE"
	kubectl create namespace "$HELM_NAMESPACE"
fi

# Install ALB Controller using Helm
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
	--create-namespace \
	--namespace "$HELM_NAMESPACE" \
	--version 1.8.12 \
	--set albController.namespace="$CONTROLLER_NAMESPACE" \
	--set albController.podIdentity.clientID=$(az identity show -g "$RESOURCE_GROUP_NAME" -n "$IDENTITY_RESOURCE_NAME" --query clientId -o tsv)

# --------------------- Check ALB Controller installation -------------------- #

# Wait for pods to be running
echo "Waiting for ALB controller pods to be running..."
kubectl wait --for=condition=Ready pods --all --namespace "$CONTROLLER_NAMESPACE" --timeout=120s

kubectl get pods -n azure-alb-system

kubectl get gatewayclass azure-alb-external -o yaml

# ---------------------------------------------------------------------------- #
#                   Application Gateway for Containers (AGC)                   #
# ---------------------------------------------------------------------------- #

# ----------------- Application Gateway for Containers (AGC) ----------------- #

AGC_NAME='alb-aks-with-nginx'

# Create an Application Gateway for Containers (AGC) instance
az network alb create -g $RESOURCE_GROUP_NAME -n $AGC_NAME

# ----------------------------- Frontend Resource ---------------------------- #

FRONTEND_NAME='alb-aks-with-nginx-frontend'

az network alb frontend create -g $RESOURCE_GROUP_NAME -n $FRONTEND_NAME --alb-name $AGC_NAME

# ----------------- Delegate a subnet to association resource ---------------- #

ALB_SUBNET_NAME='subnet-alb'

# Get AKS cluster subnet resource id
CLUSTER_SUBNET_ID=$(az vmss list --resource-group $mcResourceGroupName --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' -o tsv)

# Get Virtual Network resource id and name
read -d '' VNET_NAME VNET_RESOURCE_GROUP VNET_ID <<< $(az network vnet show --ids $CLUSTER_SUBNET_ID --query '[name, resourceGroup, id]' -o tsv)

echo "AKS Cluster is deployed in VNet: $VNET_NAME (Resource Group: $mcResourceGroupName)"

# Derive a non-overlapping subnet prefix within the VNet address space (defaulting to /24 slices when possible)
VNET_PRIMARY_PREFIX=$(az network vnet show --ids $VNET_ID --query 'addressSpace.addressPrefixes[0]' -o tsv)
EXISTING_SUBNET_PREFIXES=$(az network vnet subnet list --resource-group $mcResourceGroupName --vnet-name $VNET_NAME --query '[].addressPrefix' -o tsv)

ALB_SUBNET_PREFIX=$(VNET_PRIMARY_PREFIX="$VNET_PRIMARY_PREFIX" EXISTING_SUBNET_PREFIXES="$EXISTING_SUBNET_PREFIXES" python3 "$SUBNET_HELPER")

if [ -z "$ALB_SUBNET_PREFIX" ]; then
	echo "Failed to compute a non-overlapping subnet prefix within $VNET_PRIMARY_PREFIX" >&2
	exit 1
fi

echo "Creating AGC subnet $ALB_SUBNET_NAME with prefix $ALB_SUBNET_PREFIX in VNet $VNET_NAME"

# Create a new subnet for AGC within the same Virtual Network as the AKS cluster
az network vnet subnet create --resource-group $mcResourceGroupName --vnet-name $VNET_NAME --name $ALB_SUBNET_NAME --address-prefixes $ALB_SUBNET_PREFIX

# Enable subnet delegation for the Application Gateway for Containers service
az network vnet subnet update --resource-group $mcResourceGroupName --name $ALB_SUBNET_NAME --vnet-name $VNET_NAME --delegations 'Microsoft.ServiceNetworking/trafficControllers'

ALB_SUBNET_ID=$(az network vnet subnet list --resource-group $mcResourceGroupName --vnet-name $VNET_NAME --query "[?name=='$ALB_SUBNET_NAME'].id" --output tsv)

echo "AGC Subnet created with Resource ID: $ALB_SUBNET_ID"

# ----------------- Delegate premissions to managed identity ----------------- #

resourceGroupId=$(az group show --name $RESOURCE_GROUP_NAME --query id -otsv)

# Delegate AppGw for Containers Configuration Manager role to RG containing Application Gateway for Containers resource
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $resourceGroupId --role "fbc52c3f-28ad-4303-a892-8a056630b8f1"

# Delegate Network Contributor permission for join to association subnet
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "4d97b98b-1d4f-4787-a291-c67834d212e7"

# ---------------------- Create an association resource ---------------------- #

ASSOCIATION_NAME='alb-aks-with-nginx-association'

az network alb association create -g $RESOURCE_GROUP_NAME -n $ASSOCIATION_NAME --alb-name $AGC_NAME --subnet $ALB_SUBNET_ID