#!/bin/bash
set -e

WHITE='\033[1;37m'
NC='\033[0m' 

# A function to print and execute commands
run() {
    printf "${WHITE}➜ %s${NC}\n" "$*"
    "$@"
}

# Verification Step - Confirm Subscription
echo -e "\n🔎 Checking current Azure subscription..."
SUBSCRIPTION_ID="$(az account show --query name --output tsv)"
echo -e "\nCurrent Azure subscription ID is: ${SUBSCRIPTION_ID}"
read -p "Are you sure you want to proceed with this subscription? (yes/no): " proceed
if [[ "${proceed}" != "yes" ]]; then
  echo "Exiting the script."
  exit 1
fi

# Resource names
RESOURCE_GROUP_NAME="rg-demo"
AKS_CLUSTER_NAME="aks-demo"
IDENTITY_NAME="mi-demo"
KEYVAULT_NAME="kv-azmi-demo"
LOCATION="eastus"
SERVICE_ACCOUNT_NAME="sa-workload-identity"
SERVICE_ACCOUNT_NAMESPACE="ns-demo"

echo -e "\n🌐 Creating Resource Group & AKS Cluster with OIDC Issuer enabled..."
run az group create -l westus -n "${RESOURCE_GROUP_NAME}" | tail -n 5
run az aks create -g "${RESOURCE_GROUP_NAME}" -n "${AKS_CLUSTER_NAME}" --node-count 1 --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys | tail -n 5

echo -e "\n🔐 Setting up OIDC and Subscription IDs variables..."
AKS_OIDC_ISSUER="$(az aks show -n "${AKS_CLUSTER_NAME}" -g "${RESOURCE_GROUP_NAME}" --query "oidcIssuerProfile.issuerUrl" -otsv)"

echo -e "\n🆔 Creating Managed Identity on AAD..."
run az identity create --name "${IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --location "${LOCATION}" --subscription "${SUBSCRIPTION_ID}" | tail -n 5
sleep 30
IDENTITY_CLIENT_ID="$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${IDENTITY_NAME}" --query 'clientId' -otsv)"
IDENTITY_PRINCIPAL_ID="$(az identity show --resource-group "${RESOURCE_GROUP_NAME}" --name "${IDENTITY_NAME}" --query 'principalId' -otsv)"
run run az role assignment create --role Reader --assignee "${IDENTITY_PRINCIPAL_ID}" --subscription "${SUBSCRIPTION_ID}"

echo -e "\n🔑 Authenticating to Kubernetes..."
run az aks get-credentials -n "${AKS_CLUSTER_NAME}" -g "${RESOURCE_GROUP_NAME}" --overwrite-existing | tail -n 5

echo -e "\n🛠️ Creating a namespace and service account..."
run kubectl create namespace "${SERVICE_ACCOUNT_NAMESPACE}" | tail -n 5

cat <<EOF | kubectl apply -f - | tail -n 5
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${IDENTITY_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
  name: "${SERVICE_ACCOUNT_NAME}"
  namespace: "${SERVICE_ACCOUNT_NAMESPACE}"
EOF

echo -e "\n🤝 Setting up federation on managed identity (this configures trust relationship between AKS and AAD)..."
run az identity federated-credential create --name FederatedIdentityDemo --identity-name "${IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --issuer "${AKS_OIDC_ISSUER}" --subject system:serviceaccount:"${SERVICE_ACCOUNT_NAMESPACE}":"${SERVICE_ACCOUNT_NAME}" | tail -n 5

echo -e "\n🐳 Creating a Pod..."
cat <<EOF | kubectl apply -f - | tail -n 5
apiVersion: v1
kind: Pod
metadata:
  name: azclipod
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
    - image: mcr.microsoft.com/azure-cli:latest
      name: cli
      command:
        - "/bin/bash"
        - "-c"
        - "sleep infinity"
  nodeSelector:
    kubernetes.io/os: linux
EOF

echo -e "\n🔬 Describing Pod..."
run kubectl describe pod --namespace "${SERVICE_ACCOUNT_NAMESPACE}" azclipod | tail -n 5

# Verification Step - Connect to the Pod
read -p "Do you want to connect to the Pod now? (yes/no): " connect
if [[ "${connect}" == "yes" ]]; then
  echo "Use the following command to test pod identity, once you are connected:"
  AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
  echo "$ az login --federated-token "'$(cat /var/run/secrets/azure/tokens/azure-identity-token)'" --debug --service-principal -u ${IDENTITY_CLIENT_ID} -t ${AZURE_TENANT_ID}" 
  echo "Connecting to the Pod..."
  
  kubectl exec -it --namespace "${SERVICE_ACCOUNT_NAMESPACE}" azclipod /bin/bash
else
  echo "You can connect to the Pod later using: kubectl exec -it --namespace ${SERVICE_ACCOUNT_NAMESPACE} azclipod /bin/bash"
fi
