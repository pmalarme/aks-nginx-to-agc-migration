#!/bin/bash

# This script deploys a test application with NGINX controller
# Source: https://learn.microsoft.com/en-us/azure/aks/app-routing-nginx-configuration?tabs=azure-cli&pivots=nginx-ingress-controller

# ---------------------------------------------------------------------------- #
#                                 Prerequisites                                #
# ---------------------------------------------------------------------------- #

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

az login

# ---------------------------------------------------------------------------- #
#                              Deploy AKS Cluster                              #
# ---------------------------------------------------------------------------- #

AKS_NAME='aks-with-nginx'
RESOURCE_GROUP_NAME='rg-aks-with-nginx'
LOCATION='germanywestcentral'
VM_SIZE='Standard_D2as_v5' # The size needs to be available in your location

# ------------------------------ Resource Group ------------------------------ #

az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"

# ------------------------------------ AKS ----------------------------------- #

# Create AKS cluster with OIDC issuer and workload identity enabled
az aks create \
	--resource-group "$RESOURCE_GROUP_NAME" \
	--name "$AKS_NAME" \
	--location "$LOCATION" \
	--node-vm-size "$VM_SIZE" \
  --network-plugin azure \
	--generate-ssh-key \
  --enable-app-routing

# ---------------------------------------------------------------------------- #
#                              Deploy Application                              #
# ---------------------------------------------------------------------------- #

# Get AKS credentials for kubectl
az aks get-credentials --resource-group "$RESOURCE_GROUP_NAME" --name "$AKS_NAME"

# Create namespace for application
kubectl create namespace aks-store

# Deploy sample application manifests
kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/aks-store-demo/main/sample-manifests/docs/app-routing/aks-store-deployments-and-services.yaml -n aks-store

# Deploy Ingress
kubectl apply -n aks-store -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: store-front
  namespace: aks-store
spec:
  ingressClassName: webapprouting.kubernetes.azure.com
  rules:
  - http:
      paths:
      - backend:
          service:
            name: store-front
            port:
              number: 80
        path: /
        pathType: Prefix
EOF

# Verify deployment
kubectl get ingress -n aks-store

kubectl get service -n app-routing-system nginx -o jsonpath="{.status.loadBalancer.ingress[0].ip}"

echo ""