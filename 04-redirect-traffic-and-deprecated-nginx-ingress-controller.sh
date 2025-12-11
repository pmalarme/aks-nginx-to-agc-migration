#!/bin/bash

# First redirect traffic to Application Gateway for Containers (AGC).
# Then deprecate NGINX Ingress Controller from the AKS cluster
# Source: https://learn.microsoft.com/en-us/azure/aks/app-routing#remove-the-application-routing-add-on
# Source: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/migrate-from-agic-to-agc#step-5-deprecate-application-gateway-ingress-controller

# If NGINX was deployed with helm, use `helm uninstall` to remove it
# Example:
# helm uninstall nginx-ingress -n ingress-nginx

# Delete the existing Ingress resources that reference the NGINX Ingress Controller
# Do it for each ingress deployed in the cluster that uses NGINX
kubectl delete ingress store-front -n aks-store

AKS_NAME='aks-with-nginx'
RESOURCE_GROUP_NAME='rg-aks-with-nginx'

# Disable App Routing add-on
az aks approuting disable --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP_NAME"

# Remove the NGINX Ingress Controller (App routing) namespace if it is no longer needed
kubectl delete ns app-routing-system