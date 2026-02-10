## Reliably delete a resources group which contains a VM
RG_NAME="demo_rg_8254"
az group delete --name "$RG_NAME" --force-deletion-types Microsoft.Compute/VirtualMachines