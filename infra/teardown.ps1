<#
.SYNOPSIS
    Deletes the resource group for ContainerServices01 and everything in it,
    so nothing keeps incurring cost.
.DESCRIPTION
    Deletes the whole resource group (not individual resources) - this
    includes the ACR, Log Analytics workspace, Container Apps environment,
    and the dev/prod container apps - so any resource added under it later
    gets cleaned up too without needing to update this script. Blocks until
    Azure confirms the deletion is complete, since "the command returned"
    isn't the same as "billing stopped" if run with --no-wait.

    Deliberately leaves the GitHub Actions identity in place: the app
    registration, service principal, and federated credential live in Azure AD
    (not this resource group), cost nothing, and are reused by the next
    standup.ps1. Deleting them would force a clean-slate rebuild that also
    changes the Client ID. This teardown targets cost, and Azure AD objects are
    free, so removing the resource group is sufficient to stop all billing.
.PARAMETER Force
    Skip the interactive confirmation prompt.
#>
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/config.ps1"

$exists = az group exists --name $ResourceGroupName | ConvertFrom-Json
if (-not $exists) {
    Write-Host "Resource group '$ResourceGroupName' does not exist. Nothing to do."
    exit 0
}

if (-not $Force) {
    Write-Host "This will permanently delete resource group '$ResourceGroupName' and everything in it."
    $confirmation = Read-Host "Type the resource group name to confirm"
    if ($confirmation -ne $ResourceGroupName) {
        Write-Host "Confirmation did not match. Aborting."
        exit 1
    }
}

Write-Host "Deleting resource group '$ResourceGroupName' (this can take a few minutes)..."
az group delete --name $ResourceGroupName --yes --output none

Write-Host "Done. Resource group '$ResourceGroupName' and all resources in it are deleted."
Write-Host "All billing for this project has stopped."
Write-Host "The GitHub Actions identity (app registration / SP / federated credential)"
Write-Host "remains in Azure AD at no cost and will be reused by the next standup."
