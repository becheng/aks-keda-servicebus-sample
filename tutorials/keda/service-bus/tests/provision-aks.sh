#!/bin/bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/00-provision-aks.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -f "$TEST_DIR/key.pub" "$TEST_DIR/commands" "$TEST_DIR/output"; rmdir "$TEST_DIR"' EXIT
export TEST_DIR
export EXPECTED_SUBSCRIPTION_ID="11111111-1111-1111-1111-111111111111"
export AKS_ADMIN_GROUP_OBJECT_ID="22222222-2222-2222-2222-222222222222"
export AKS_SSH_PUBLIC_KEY="$TEST_DIR/key.pub"
printf 'test public key\n' >"$AKS_SSH_PUBLIC_KEY"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Replace Azure only at the CLI boundary. No test can deploy resources.
az() {
  printf '%s ' "$@" >>"$TEST_DIR/commands"
  printf '\n' >>"$TEST_DIR/commands"
  case "$1 $2" in
    "account show")
      case "$*" in
        *"--query id"*) echo "${TEST_SUBSCRIPTION:-$EXPECTED_SUBSCRIPTION_ID}" ;;
        *"--query tenantId"*) echo "33333333-3333-3333-3333-333333333333" ;;
        *"--query name"*) echo "Test subscription" ;;
        *) return 90 ;;
      esac
      ;;
    "cloud show") echo "${TEST_ARM_ENDPOINT:-https://management.azure.com/}" ;;
    "provider show") echo "Registered" ;;
    "group create") ;;
    "resource list")
      if [[ ${TEST_LIST_FAILURE:-false} == true ]]; then
        echo "AuthorizationFailed: test resource-list failure" >&2
        return 1
      fi
      if [[ ${TEST_EXISTING:-false} == true ]]; then
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/test/existing"
      fi
      ;;
    "network vnet")
      if [[ $3 == create && ${TEST_VNET_FAILURE:-false} == true ]]; then
        echo "RequestDisallowedByPolicy: test VNet failure" >&2
        return 1
      fi
      if [[ $3 == show ]]; then
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.Network/virtualNetworks/local-vnet-test"
      elif [[ $3 == subnet && $4 == show ]]; then
        local subnet=SystemSubnet
        if [[ $* == *"--name UserSubnet"* ]]; then subnet=UserSubnet; fi
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.Network/virtualNetworks/local-vnet-test/subnets/$subnet"
      elif [[ $3 == subnet && $4 == list && ${TEST_EXISTING:-false} == true ]]; then
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.Network/virtualNetworks/local-vnet-test/subnets/UserSubnet"
      fi
      ;;
    "identity create"|"acr create") ;;
    "role assignment")
      if [[ $3 == create && ${TEST_ROLE_FAILURE:-false} == true ]]; then
        echo "AuthorizationFailed: test role-assignment failure" >&2
        return 1
      fi
      ;;
    "identity show")
      if [[ $* == *"--query principalId"* ]]; then
        echo "44444444-4444-4444-4444-444444444444"
      else
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/local-aks-identity-test"
      fi
      ;;
    "acr show")
      echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.ContainerRegistry/registries/akskeda2194b8"
      ;;
    "aks get-versions") echo "1.36" ;;
    "aks create") ;;
    "aks nodepool")
      if [[ $3 == show ]]; then
        echo "true"
      elif [[ $3 == list && ${TEST_EXISTING:-false} == true ]]; then
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.ContainerService/managedClusters/local-aks-test/agentPools/user"
      fi
      ;;
    "aks show")
      if [[ $* == *"--query identityProfile.kubeletidentity.objectId"* ]]; then
        echo "55555555-5555-5555-5555-555555555555"
      elif [[ $* == *"--query id"* ]]; then
        echo "/subscriptions/$EXPECTED_SUBSCRIPTION_ID/resourceGroups/local-rg/providers/Microsoft.ContainerService/managedClusters/local-aks-test"
      else
        echo "${TEST_CLUSTER_MATCHES:-true}"
      fi
      ;;
    *) echo "Unexpected Azure command: $1 $2" >&2; return 90 ;;
  esac
}
kubectl() { :; }
kubelogin() { :; }
ssh-keygen() { :; }
sleep() { :; }
export -f az kubectl kubelogin ssh-keygen sleep

run_provision() {
  : >"$TEST_DIR/commands"
  bash "$SCRIPT" >"$TEST_DIR/output" 2>&1
}

[[ -f $SCRIPT ]] || fail "Reduced provisioning script is missing"

run_provision || { cat "$TEST_DIR/output"; fail "Minimal provisioning failed"; }
grep -q '^aks create .*--network-dataplane cilium .*--network-plugin azure .*--network-plugin-mode overlay ' "$TEST_DIR/commands" ||
  fail "AKS must use Azure CNI Overlay with Cilium"
grep -q '^aks create .*--node-count 1 .*--min-count 1 .*--max-count 3 ' "$TEST_DIR/commands" ||
  fail "System node pool must use the approved autoscaling bounds"
grep -q '^aks nodepool add .*--node-count 1 .*--min-count 1 .*--max-count 3 ' "$TEST_DIR/commands" ||
  fail "User node pool must use the approved autoscaling bounds"
grep -q '^role assignment create .*--role AcrPull ' "$TEST_DIR/commands" ||
  fail "Kubelet must receive registry pull access"
grep -q '^role assignment create .*--role Azure Kubernetes Service RBAC Cluster Admin ' "$TEST_DIR/commands" ||
  fail "Approved Entra group must receive AKS administrator access"
if grep -Eiq 'bastion|keyvault|log-analytics|diagnostic-settings|--windows-admin|--enable-acns|--enable-gateway-api|--enable-addons monitoring' "$TEST_DIR/commands"; then
  fail "Provisioning requested an excluded feature"
fi
if grep -E '^(group create|network |identity create|acr create|aks |role assignment create)' "$TEST_DIR/commands" |
  grep -v -- "--subscription $EXPECTED_SUBSCRIPTION_ID" >/dev/null; then
  fail "Azure resource commands must pin the approved subscription"
fi
echo "PASS: minimal resources, approved networking, node pools, and scoped access"

export TEST_EXISTING=true
run_provision || { cat "$TEST_DIR/output"; fail "Reusing existing resources failed"; }
if grep -Eq '^(network vnet (create|subnet create)|identity create|acr create|aks create|aks nodepool add) ' "$TEST_DIR/commands"; then
  fail "Existing resources were created again"
fi
unset TEST_EXISTING
echo "PASS: existing resources are reused without duplicate creation"

export TEST_CLUSTER_MATCHES=false
if run_provision; then fail "Incompatible cluster was accepted"; fi
if grep -q '^aks nodepool add ' "$TEST_DIR/commands"; then fail "Incompatible cluster was modified"; fi
unset TEST_CLUSTER_MATCHES
echo "PASS: incompatible cluster stops before user-pool creation"

export TEST_SUBSCRIPTION="99999999-9999-9999-9999-999999999999"
if run_provision; then fail "Wrong subscription was accepted"; fi
grep -qi 'subscription' "$TEST_DIR/output" || fail "Missing subscription error"
if grep -Eq '^(group create|network |identity create|acr create|aks create)' "$TEST_DIR/commands"; then
  fail "Wrong subscription caused resource changes"
fi
unset TEST_SUBSCRIPTION
echo "PASS: wrong subscription stops before resource changes"

export TEST_ARM_ENDPOINT="https://emulator.invalid/"
if run_provision; then fail "Non-Azure endpoint was accepted"; fi
if grep -q '^group create ' "$TEST_DIR/commands"; then fail "Non-Azure endpoint caused resource changes"; fi
unset TEST_ARM_ENDPOINT
echo "PASS: non-Azure target is rejected"

export TEST_LIST_FAILURE=true
if run_provision; then fail "Failed lookup was treated as a missing resource"; fi
if grep -q '^network vnet create ' "$TEST_DIR/commands"; then fail "Failed lookup caused VNet creation"; fi
unset TEST_LIST_FAILURE
echo "PASS: failed resource lookup stops instead of triggering creation"

export TEST_VNET_FAILURE=true
if run_provision; then fail "Failed VNet creation was ignored"; fi
if grep -q '^aks create ' "$TEST_DIR/commands"; then fail "Cluster creation continued after VNet failure"; fi
unset TEST_VNET_FAILURE
echo "PASS: failed provisioning stops dependent operations"

export TEST_ROLE_FAILURE=true
if run_provision; then fail "Role-assignment failures were ignored"; fi
[[ $(grep -c '^role assignment create ' "$TEST_DIR/commands") == 5 ]] ||
  fail "Role-assignment retries were not bounded"
if grep -q '^aks create ' "$TEST_DIR/commands"; then fail "Cluster creation continued without network access"; fi
unset TEST_ROLE_FAILURE
echo "PASS: role-assignment failures stop provisioning after bounded retries"
