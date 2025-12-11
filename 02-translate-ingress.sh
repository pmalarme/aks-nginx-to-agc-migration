#!/bin/bash

# Migrate an existing NGINX Ingress deployment to Application Gateway for Containers (AGC)
# Source: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/migrate-from-agic-to-agc#annotations

RESOURCE_GROUP_NAME='rg-aks-with-nginx'
AGC_NAME='alb-aks-with-nginx'
FRONTEND_NAME='alb-aks-with-nginx-frontend'

# Get the Application Gateway Ingress Controller's resource id
AGC_ID=$(az network alb show --resource-group $RESOURCE_GROUP_NAME --name $AGC_NAME --query id -o tsv)

# Deploy Ingress
kubectl apply -n aks-store -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: store-front-agc
  namespace: aks-store
  annotations:
    alb.networking.azure.io/alb-id: $AGC_ID
    alb.networking.azure.io/alb-frontend: $FRONTEND_NAME
spec:
  ingressClassName: azure-alb-external
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

# Wait for ingress controller creation
echo "Waiting for Application Gateway Ingress Controller to create the Ingress resource..."
sleep 30

# Get the deployed Ingress resource
kubectl get ingress store-front-agc -n aks-store -o yaml

# Get the FQDN of the Application Gateway frontend
fqdn=$(kubectl get ingress store-front-agc -n aks-store -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Get the IP address for this FQDN
fqdnIp=$(dig +short $fqdn)

echo "Application Gateway for Containers FQDN: $fqdn"
echo "Application Gateway for Containers IP: $fqdnIp"
echo "http://$fqdn"
