#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: AKS prerequisite provisioning failed at line $LINENO." >&2' ERR

if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
  export MSYS_NO_PATHCONV=1
  set -o igncr
  export SHELLOPTS
fi

for tool in az kubectl kubelogin ssh-keygen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool [$tool] is not available in PATH." >&2
    exit 1
  fi
done

: "${EXPECTED_SUBSCRIPTION_ID:?Set EXPECTED_SUBSCRIPTION_ID to the approved Azure subscription ID.}"
: "${AKS_ADMIN_GROUP_OBJECT_ID:?Set AKS_ADMIN_GROUP_OBJECT_ID to the approved Entra security group object ID.}"
AKS_SSH_PUBLIC_KEY="${AKS_SSH_PUBLIC_KEY:-$HOME/.ssh/id_rsa_aks_sample.pub}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for value in "$EXPECTED_SUBSCRIPTION_ID" "$AKS_ADMIN_GROUP_OBJECT_ID"; do
  [[ $value =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
    fail "Subscription and administrator group IDs must be GUIDs."
done

CURRENT_SUBSCRIPTION_ID="$(az account show --query id --output tsv --only-show-errors)"
[[ $CURRENT_SUBSCRIPTION_ID == "$EXPECTED_SUBSCRIPTION_ID" ]] ||
  fail "The active subscription does not match EXPECTED_SUBSCRIPTION_ID."
ARM_ENDPOINT="$(az cloud show --query endpoints.resourceManager --output tsv --only-show-errors)"
[[ $ARM_ENDPOINT == https://management.azure.com/ ]] ||
  fail "This script requires the public Azure Resource Manager endpoint."

[[ -f $AKS_SSH_PUBLIC_KEY ]] || fail "SSH public key not found at [$AKS_SSH_PUBLIC_KEY]."
if command -v cygpath >/dev/null 2>&1; then
  AKS_SSH_PUBLIC_KEY="$(cygpath -m "$AKS_SSH_PUBLIC_KEY")"
fi
ssh-keygen -l -f "$AKS_SSH_PUBLIC_KEY" >/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-variables.sh"

# Pin every resource operation even if another terminal changes the CLI default.
azure() {
  az "$@" --subscription "$EXPECTED_SUBSCRIPTION_ID" --only-show-errors
}

resource_id() {
  azure resource list --resource-group "$AKS_RESOURCE_GROUP_NAME" \
    --resource-type "$1" --query "[?name=='$2'].id | [0]" --output tsv
}

grant_role() {
  local role=$1 principal=$2 scope=$3 principal_type=$4 assignment attempt
  assignment="$(azure role assignment list --scope "$scope" \
    --query "[?principalId=='$principal' && roleDefinitionName=='$role'].id | [0]" --output tsv)"
  [[ -z $assignment ]] || return 0
  for ((attempt=1; attempt<=RETRY_COUNT; attempt++)); do
    if azure role assignment create --role "$role" --assignee-object-id "$principal" \
      --assignee-principal-type "$principal_type" --scope "$scope" --output none; then
      return 0
    fi
    echo "Role assignment [$role] failed (attempt $attempt of $RETRY_COUNT)." >&2
    if (( attempt < RETRY_COUNT )); then sleep "$SLEEP"; fi
  done
  fail "Could not assign [$role] on [$scope]."
}

for provider in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Network \
  Microsoft.Compute Microsoft.ManagedIdentity Microsoft.ServiceBus; do
  STATE="$(azure provider show --namespace "$provider" --query registrationState --output tsv)"
  [[ $STATE == Registered ]] || fail "Register [$provider] before running this script."
done

KUBERNETES_VERSION="$(azure aks get-versions --location "$LOCATION" \
  --query 'values[?isDefault==`true`].version | [0]' --output tsv)"
[[ -n $KUBERNETES_VERSION ]] || fail "No default AKS version was returned for [$LOCATION]."

VNET_NAME="${PREFIX}-vnet-${SUFFIX}"
CLUSTER_IDENTITY_NAME="${PREFIX}-aks-identity-${SUFFIX}"

echo "Provisioning sample prerequisites in [$LOCATION] on subscription [$EXPECTED_SUBSCRIPTION_ID]."
azure group create --name "$AKS_RESOURCE_GROUP_NAME" --location "$LOCATION" --output none

VNET_ID="$(resource_id Microsoft.Network/virtualNetworks "$VNET_NAME")"
if [[ -z $VNET_ID ]]; then
  azure network vnet create --name "$VNET_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
    --location "$LOCATION" --address-prefixes 10.0.0.0/8 --subnet-name SystemSubnet \
    --subnet-prefix 10.240.0.0/16 --output none
fi
VNET_ID="$(azure network vnet show --name "$VNET_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
  --query id --output tsv)"
[[ -n $VNET_ID ]] || fail "The virtual network ID is empty."

USER_SUBNET_ID="$(azure network vnet subnet list --vnet-name "$VNET_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" --query "[?name=='UserSubnet'].id | [0]" --output tsv)"
if [[ -z $USER_SUBNET_ID ]]; then
  azure network vnet subnet create --name UserSubnet --vnet-name "$VNET_NAME" \
    --resource-group "$AKS_RESOURCE_GROUP_NAME" --address-prefixes 10.241.0.0/16 --output none
fi
SYSTEM_SUBNET_ID="$(azure network vnet subnet show --name SystemSubnet --vnet-name "$VNET_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" --query id --output tsv)"
USER_SUBNET_ID="$(azure network vnet subnet show --name UserSubnet --vnet-name "$VNET_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" --query id --output tsv)"
[[ -n $SYSTEM_SUBNET_ID && -n $USER_SUBNET_ID ]] || fail "A node subnet ID is empty."

IDENTITY_ID="$(resource_id Microsoft.ManagedIdentity/userAssignedIdentities "$CLUSTER_IDENTITY_NAME")"
if [[ -z $IDENTITY_ID ]]; then
  azure identity create --name "$CLUSTER_IDENTITY_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
    --location "$LOCATION" --output none
fi
IDENTITY_ID="$(azure identity show --name "$CLUSTER_IDENTITY_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" --query id --output tsv)"
IDENTITY_PRINCIPAL_ID="$(azure identity show --name "$CLUSTER_IDENTITY_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" --query principalId --output tsv)"
[[ -n $IDENTITY_ID && -n $IDENTITY_PRINCIPAL_ID ]] || fail "The cluster identity is incomplete."
grant_role "Network Contributor" "$IDENTITY_PRINCIPAL_ID" "$VNET_ID" ServicePrincipal

ACR_ID="$(resource_id Microsoft.ContainerRegistry/registries "$ACR_NAME")"
if [[ -z $ACR_ID ]]; then
  azure acr create --name "$ACR_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
    --location "$LOCATION" --sku Basic --admin-enabled false --output none
fi
ACR_ID="$(azure acr show --name "$ACR_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
  --query id --output tsv)"
[[ -n $ACR_ID ]] || fail "The registry ID is empty."

AKS_ID="$(resource_id Microsoft.ContainerService/managedClusters "$AKS_NAME")"
if [[ -z $AKS_ID ]]; then
  azure aks create --name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
    --location "$LOCATION" --kubernetes-version "$KUBERNETES_VERSION" \
    --nodepool-name system --os-sku AzureLinux --node-vm-size Standard_D4ds_v5 \
    --node-osdisk-type Ephemeral --node-osdisk-size 50 \
    --node-count 1 --min-count 1 --max-count 3 --enable-cluster-autoscaler --max-pods 100 \
    --vnet-subnet-id "$SYSTEM_SUBNET_ID" --network-dataplane cilium --network-policy cilium \
    --network-plugin azure --network-plugin-mode overlay --pod-cidr 192.168.0.0/16 \
    --service-cidr 172.16.0.0/16 --dns-service-ip 172.16.0.10 \
    --enable-managed-identity --assign-identity "$IDENTITY_ID" \
    --enable-keda --enable-oidc-issuer --enable-workload-identity \
    --enable-aad --enable-azure-rbac --disable-local-accounts \
    --aad-admin-group-object-ids "$AKS_ADMIN_GROUP_OBJECT_ID" \
    --ssh-key-value "$AKS_SSH_PUBLIC_KEY" --zones 1 2 3 --output none
fi

CLUSTER_MATCHES="$(azure aks show --name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
  --query "provisioningState=='Succeeded' && location=='${LOCATION,,}' && networkProfile.networkPlugin=='azure' && networkProfile.networkPluginMode=='overlay' && networkProfile.networkDataplane=='cilium' && oidcIssuerProfile.enabled==\`true\` && securityProfile.workloadIdentity.enabled==\`true\` && workloadAutoScalerProfile.keda.enabled==\`true\` && aadProfile.enableAzureRbac==\`true\` && contains(aadProfile.adminGroupObjectIDs, '$AKS_ADMIN_GROUP_OBJECT_ID')" \
  --output tsv)"
[[ $CLUSTER_MATCHES == true ]] || fail "The cluster does not match the required region, networking, identity, or KEDA settings."
AKS_ID="$(azure aks show --name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
  --query id --output tsv)"
KUBELET_PRINCIPAL_ID="$(azure aks show --name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
  --query identityProfile.kubeletidentity.objectId --output tsv)"
[[ -n $AKS_ID && -n $KUBELET_PRINCIPAL_ID ]] || fail "The cluster ID or kubelet identity is empty."
grant_role AcrPull "$KUBELET_PRINCIPAL_ID" "$ACR_ID" ServicePrincipal
grant_role "Azure Kubernetes Service RBAC Cluster Admin" "$AKS_ADMIN_GROUP_OBJECT_ID" "$AKS_ID" Group

USER_POOL_ID="$(azure aks nodepool list --cluster-name "$AKS_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" --query "[?name=='user'].id | [0]" --output tsv)"
if [[ -z $USER_POOL_ID ]]; then
  azure aks nodepool add --name user --cluster-name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP_NAME" \
    --mode User --os-type Linux --os-sku AzureLinux --node-vm-size Standard_D4ds_v5 \
    --node-osdisk-type Ephemeral --node-osdisk-size 50 \
    --node-count 1 --min-count 1 --max-count 3 --enable-cluster-autoscaler --max-pods 100 \
    --vnet-subnet-id "$USER_SUBNET_ID" --zones 1 2 3 --output none
fi
USER_POOL_MATCHES="$(azure aks nodepool show --name user --cluster-name "$AKS_NAME" \
  --resource-group "$AKS_RESOURCE_GROUP_NAME" \
  --query "provisioningState=='Succeeded' && osType=='Linux' && vmSize=='Standard_D4ds_v5' && vnetSubnetId=='$USER_SUBNET_ID' && enableAutoScaling==\`true\` && minCount==\`1\` && maxCount==\`3\`" --output tsv)"
[[ $USER_POOL_MATCHES == true ]] || fail "The user node pool does not match the sample configuration."

echo "SUCCESS: AKS prerequisites are ready. Run 01-enable-keda.sh next."
