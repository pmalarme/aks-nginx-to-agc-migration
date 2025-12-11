#!/bin/bash

# Deploy a test application to verify AGC setup with SSL termination
# Source: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/how-to-ssl-offloading-ingress-api?tabs=byo

# ---------------------------------------------------------------------------- #
#                        Deploy sample HTTPS application                       #
# ---------------------------------------------------------------------------- #

kubectl apply -f https://raw.githubusercontent.com/MicrosoftDocs/azure-docs/refs/heads/main/articles/application-gateway/for-containers/examples/https-scenario/ssl-termination/deployment.yaml

# ---------------------------------------------------------------------------- #
#                   Deploy the required Ingress API resources                  #
# ---------------------------------------------------------------------------- #

RESOURCE_GROUP_NAME='rg-aks-with-agc'
AGC_NAME='alb-aks-with-agc'
FRONTEND_NAME='alb-aks-with-agc-frontend'

# Get the Application Gateway Ingress Controller's resource id
AGC_ID=$(az network alb show --resource-group $RESOURCE_GROUP_NAME --name $AGC_NAME --query id -o tsv)

# Create the Ingress resource with SSL termination
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-01
  namespace: test-infra
  annotations:
    alb.networking.azure.io/alb-id: $AGC_ID
    alb.networking.azure.io/alb-frontend: $FRONTEND_NAME
spec:
  # azure-alb-external is the IngressClass installed by the ALB controller; it
  # binds this ingress to the external Application Gateway frontend managed by
  # Application Gateway for Containers.
  ingressClassName: azure-alb-external
  tls:
  - hosts:
    - example.com
    secretName: listener-tls-secret
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: echo
            port:
              number: 80
EOF

# Get the deployed Ingress resource
kubectl get ingress ingress-01 -n test-infra -o yaml

# ---------------------------------------------------------------------------- #
#                                     Test                                     #
# ---------------------------------------------------------------------------- #

# Get the FQDN of the Application Gateway frontend
fqdn=$(kubectl get ingress ingress-01 -n test-infra -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Get the IP address for this FQDN
fqdnIp=$(dig +short $fqdn)

# Test HTTPS connectivity to the test application via the Application Gateway
curl -vik --resolve example.com:443:$fqdnIp https://example.com