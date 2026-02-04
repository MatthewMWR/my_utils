#!/usr/bin/env bash
set -euo pipefail

## Assumes Azure CLI is installed and you are logged in
## vm creation will prompt for a password for the local admin account 

## Parameters to customize, from most to least likely you wouldn't want to keep the defaults
loc="westus2"
machineAdminUserName="azureuser"
rgPrefix="demo_rg_"
vmPrefix="demo-vm-"

# ---- Random 4-digit suffix ----
# Bash $RANDOM returns 0–32767; scale it into [1000..9999]. 【1-813441】【2-c180c4】
suffix=$((1000 + RANDOM % 9000))

rg="${rgPrefix}${suffix}"
vm="${vmPrefix}${suffix}"

# ---- Create resource group ----
az group create --name "$rg" --location "$loc"

# ---- Create Windows Server VM ----
az vm create \
  --resource-group "$rg" \
  --name "$vm" \
  --image "MicrosoftWindowsServer:WindowsServer:2025-datacenter-azure-edition-core:latest" \
  --admin-username "$machineAdminUserName" \
  --public-ip-sku Standard

# ---- Open inbound SSH (TCP 22) via NSG rule ----
# az vm open-port supports specifying the port (or range) and uses NSG rule priority mechanics. 【3-6d4bd1】
az vm open-port --resource-group "$rg" --name "$vm" --port 22 > /dev/null

echo "CREATED: $rg (resource group) and $vm (VM) with $machineAdminUserName (local account to use for demo)"

echo "IMPORTANT: SSH open to internet. Ensure you have a very strong password and to limit the lifetime of the machine"
