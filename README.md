# Migrating from NGINX Ingress Controller to Application Gateway for Containers

This repository provides a scripted walkthrough for moving an Azure Kubernetes Service (AKS) workload that currently uses the NGINX ingress controller to the Application Gateway for Containers (AGC) ingress controller. The flow mirrors the four-stage migration guidance in the [official Microsoft documentation](https://learn.microsoft.com/azure/application-gateway/for-containers/migrate-from-agic-to-agc):

1. Add ALB Controller to the cluster (and deploy AGC with a frontend if you use the BYOD model).
2. Translate existing NGINX ingress definitions to AGC-compatible ingress definitions.
3. Perform end-to-end testing to verify traffic parity between NGINX and AGC.
4. Redirect traffic to AGC and decommission NGINX.

Each stage below references the accompanying demo script so you can test the migration end-to-end or jump into a specific phase.

> [!IMPORTANT]
> * The sample script are for implemented when you [bring your own deployment for the creation of the Application Gateway for Containers (AGC)](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-byo-deployment?tabs=existing-vnet-subnet). You can adapt them to [create AGC that is managed by the ALB Controller](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-managed-by-alb-controller?tabs=new-subnet-aks-vnet).
> * The scripts are designed for demonstration purposes and may require adjustments for production use, including enhanced error handling, security practices, and environment-specific configurations.
> * The script is using the virtual network of the AKS cluster. You can also bring your own virtual network. In that case, make sure to adapt the scripts accordingly.

> [!NOTE]
> * There are other strategies to migrate from NGINX to AGC, such as blue-green deployments. Instead of deploying a second ingress controller alongside NGINX, you could set up a parallel AGC environment and switch traffic over once validated. This approach may suit scenarios where zero-downtime cutover is critical, where the existing cluster cannot accommodate for the deployment of AGC, or where immutable deployment practices are in place. If you decide to follow this strategy there are 2 scripts to deploy AKS cluster with AGC: [agc-01-deploy-aks-with-agc.sh](./agc-01-deploy-aks-with-agc.sh) and [agc-02-deploy-test-application.sh](./agc-02-deploy-test-application.sh).
> * This guide assumes familiarity with AKS, Kubernetes ingress concepts, and Azure networking. Ensure you have the necessary permissions to create and manage resources in your Azure subscription.
> * This migration from NGINX to AGC is tranlating traffic management using Ingress API to AGC traffic management using Ingress API. It is important to consider if the translation is the right approach or if you should use the Gateway API instead. Read carefully the [documentation](https://learn.microsoft.com/en-us/azure/aks/concepts-network-ingress#compare-ingress-options) to choose the right ingress and API for your scenario.
> * If your ingress definitions use advanced NGINX-specific features (like custom annotations, rewrite rules, or specific load balancing algorithms), you may need to manually adjust the AGC ingress definitions to achieve equivalent functionality. This [documentation](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/migrate-from-agic-to-agc#feature-dependencies-and-mappings) provides a mapping of AGIC features to AGC features. It could be use to check how to translate NGINX features to AGC features.

## Demo: Deploy a sample NGINX ingress environment (optional)

<details>
<summary><strong>Follow these steps to deploy a sample NGINX ingress environment</strong></summary>

> Script: [`00-deploy-aks-with-nginx.sh`](./00-deploy-aks-with-nginx.sh)

1. Spins up an AKS cluster (`aks-with-nginx`) with the Web App Routing add-on (NGINX ingress controller).
2. Installs the sample **aks-store** application (`store-front` service) into the `aks-store` namespace.
3. Creates a classic ingress (`store-front`) served by the NGINX controller.

> 💡 Already have an AKS cluster running the NGINX ingress controller? You can skip this step and move straight to Step 2.

**Run it (only if you need a demo cluster)**
```bash
bash 00-deploy-aks-with-nginx.sh
```

After execution, you should see an external IP or FQDN for the `store-front` ingress.

</details>

## Step 1 – Add ALB Controller to the cluster and deploy AGC with a frontend (BYOD model)

1. Enables workload identity on the existing AKS cluster.
2. Creates and federates a managed identity for the ALB controller.
3. Installs the AGC ALB Helm chart (`azure-alb-system` namespace) and provisions the AGC instance with its frontend.
4. Delegates a subnet to AGC and applies required role assignments.

At the end of this step, the AGC controller is running alongside NGINX, ready to accept ingress definitions.

> [!NOTE]
> **Demo script**
>
> Script: [`01-install-ALB-controller-deploy-AGC.sh`](./01-install-ALB-controller-deploy-AGC.sh)
>
> To run it: `bash 01-install-ALB-controller-deploy-AGC.sh`

## Step 2 – Translate ingress definitions to AGC

For each existing NGINX ingress resource, follow these steps:

1. Reads the existing NGINX ingress.
2. Creates an equivalent AGC ingress with the appropriate `alb.networking.azure.io` annotations and using `azure-alb-external` as the ingress class.
3. Deploys the new AGC ingress resource into the same namespace or another namespace of your choice.

This leaves the original NGINX ingress untouched while publishing the same application through the AGC controller so that you can validate traffic before cut-over for each ingress definition.

> [!NOTE]
> **Demo script**
>
> Script: [`02-translate-ingress.sh`](./02-translate-ingress.sh)
>
> To run it: `bash 02-translate-ingress.sh`

---

## Step 3 – Perform end-to-end testing

For each ingress definition migrated in Step 2, perform end-to-end testing to ensure that the AGC ingress serves the same content as the NGINX ingress.

> [!NOTE]
> **Demo script**
>
> Script: [`03-test-agc-ingress.sh`](./03-test-agc-ingress.sh)
>
> To run it:
>
> * `bash 03-test-agc-ingress.sh`
> * or specify ingresses: `bash 03-test-agc-ingress.sh <original-ingress-name> <migrated-ingress-name>`
>
> This utility compares responses from the legacy and AGC ingress endpoints to ensure the application behaves the same.

The script fetches each ingress response (handling host headers, TLS, or public IPs automatically), performs a diff, and highlights any mismatches. Matching responses confirm that AGC is ready to serve production traffic.

---

## Step 4 – Redirect traffic to AGC and retire NGINX

1. For each ingress definition migrated in Step 2, redirect the traffic from NGINX to AGC.
2. When all the traffic is redirected and validated, cleanup the NGINX ingress controller and related resources.

> [!NOTE]
> **Demo scripts**
>
> Scripts: [`04-redirect-traffic-and-deprecated-nginx-ingress-controller.sh`](./04-redirect-traffic-and-deprecated-nginx-ingress-controller.sh)
>
> To run it: `bash 04-redirect-traffic-and-deprecated-nginx-ingress-controller.sh`
> These steps finalize the migration so AGC becomes the authoritative ingress path. Retiring NGINX frees cluster capacity and removes redundant load balancers.

---

🎉 Happy migrating! Do not hesitate to reach out if you have questions or feedback—cheering you on for a smooth AGC journey! 🎉
