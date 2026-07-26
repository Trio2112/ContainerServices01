<#
.SYNOPSIS
    Brings up everything ContainerServices01 needs to run and to be deployed by
    GitHub Actions: resource group, Azure Container Registry, a Container Apps
    environment hosting dev + prod apps, the GitHub Actions federated identity,
    its ACR push permission, and the GitHub repo variables the workflow
    consumes.
.DESCRIPTION
    Fully idempotent and safe to re-run. Designed for a frequent
    teardown/standup cycle:

      * The resource group, ACR, Log Analytics workspace, Container Apps
        environment, and the dev/prod container apps are all destroyed by
        teardown.ps1, so they are (re)created here every time.
      * The dev/prod container apps start on a public placeholder image and
        pull from ACR via their own system-assigned managed identities
        (AcrPull, scoped to just the registry) - no registry credentials are
        ever stored. GitHub Actions swaps in the real image with
        `az containerapp update --image ...`.
      * The Azure AD app registration, service principal, and federated
        credential live in Azure AD (not the resource group), so they SURVIVE
        teardown. This script detects and reuses them, only creating them on a
        genuinely clean slate.
      * The AcrPush role assignment (for the GitHub Actions identity) and the
        AcrPull role assignments (for the container apps) are tied to the
        ACR's resource id, which changes every rebuild, so they are (re)granted
        here every time.
      * The GitHub repo variables are (re)synced so the workflow always has
        the current client/tenant/subscription ids and resource names.

    Requires: Azure CLI (logged in), the `containerapp` extension (installed
    automatically by this script), and, for the GitHub step, the GitHub CLI
    (`gh`) logged in. If `gh` is missing or not authenticated, the Azure work
    still completes and the values you need are printed for manual entry.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/config.ps1"

# Make sure every az call targets the intended subscription, regardless of the
# CLI's current default context.
az account set --subscription $SubscriptionId

# --- Resource group ---------------------------------------------------------
Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..."
az group create --name $ResourceGroupName --location $Location --output none

# --- Container registry -----------------------------------------------------
Write-Host "Creating container registry '$AcrName' (SKU: $AcrSku)..."
az acr create `
    --resource-group $ResourceGroupName `
    --name $AcrName `
    --sku $AcrSku `
    --admin-enabled false `
    --output none
$acrId = az acr show --name $AcrName --resource-group $ResourceGroupName --query id --output tsv

# --- Container Apps hosting (dev + prod) -------------------------------------
Write-Host "Ensuring 'containerapp' CLI extension..."
az extension add --name containerapp --upgrade --yes --only-show-errors --output none

function Ensure-ProviderRegistered([string]$Namespace) {
    $state = az provider show --namespace $Namespace --query registrationState --output tsv
    if ($state -ne "Registered") {
        Write-Host "  Registering resource provider '$Namespace' (first-time only, can take a minute)..."
        az provider register --namespace $Namespace --wait
    }
}
Write-Host "Ensuring required resource providers are registered..."
Ensure-ProviderRegistered "Microsoft.App"
Ensure-ProviderRegistered "Microsoft.OperationalInsights"

Write-Host "Creating Log Analytics workspace '$LogAnalyticsName'..."
az monitor log-analytics workspace create `
    --resource-group $ResourceGroupName `
    --workspace-name $LogAnalyticsName `
    --location $Location `
    --output none
$workspaceId  = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $LogAnalyticsName --query customerId --output tsv
$workspaceKey = az monitor log-analytics workspace get-shared-keys --resource-group $ResourceGroupName --workspace-name $LogAnalyticsName --query primarySharedKey --output tsv

Write-Host "Creating Container Apps environment '$ContainerAppsEnvName'..."
az containerapp env create `
    --name $ContainerAppsEnvName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --logs-workspace-id $workspaceId `
    --logs-workspace-key $workspaceKey `
    --output none

# Dev and prod are two separate container apps in the same environment. Each
# starts on a public placeholder image (no ACR access needed yet) and is then
# wired up to pull from ACR via its own system-assigned managed identity - no
# registry username/password is ever stored. GitHub Actions later points each
# app at the real image with `az containerapp update --image ...`.
foreach ($appName in @($ContainerAppDevName, $ContainerAppProdName)) {
    Write-Host "Ensuring container app '$appName'..."
    $exists = az containerapp show --name $appName --resource-group $ResourceGroupName --query name --output tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($exists)) {
        Write-Host "  Not found - creating on placeholder image."
        az containerapp create `
            --name $appName `
            --resource-group $ResourceGroupName `
            --environment $ContainerAppsEnvName `
            --image $PlaceholderImage `
            --target-port $ContainerAppTargetPort `
            --ingress external `
            --system-assigned `
            --output none
    } else {
        Write-Host "  Reusing existing container app."
    }

    $principalId = az containerapp show --name $appName --resource-group $ResourceGroupName --query identity.principalId --output tsv

    Write-Host "  Granting AcrPull on the registry to '$appName' managed identity..."
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role AcrPull `
        --scope $acrId `
        --output none

    Write-Host "  Wiring '$appName' to pull from ACR via its managed identity..."
    az containerapp registry set `
        --name $appName `
        --resource-group $ResourceGroupName `
        --server "$AcrName.azurecr.io" `
        --identity system `
        --output none
}

# --- Azure AD app registration (reused across teardowns) --------------------
Write-Host "Ensuring app registration '$AppDisplayName'..."
$appId = az ad app list --display-name $AppDisplayName --query "[0].appId" --output tsv
if ([string]::IsNullOrWhiteSpace($appId)) {
    Write-Host "  Not found - creating."
    $appId = az ad app create --display-name $AppDisplayName --query appId --output tsv
} else {
    Write-Host "  Reusing existing app (Client ID: $appId)."
}

# --- Service principal for that app -----------------------------------------
Write-Host "Ensuring service principal..."
$spObjectId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" --output tsv
if ([string]::IsNullOrWhiteSpace($spObjectId)) {
    Write-Host "  Not found - creating."
    $spObjectId = az ad sp create --id $appId --query id --output tsv
} else {
    Write-Host "  Reusing existing service principal (object id: $spObjectId)."
}

# --- Federated credentials (the GitHub OIDC trust) - one per trusted branch -
foreach ($branch in $TrustedBranches) {
    $credName = "gh-$branch-branch"
    $subject  = "repo:$($GitHubRepo):ref:refs/heads/$branch"
    Write-Host "Ensuring federated credential '$credName' (branch: $branch)..."
    $fedExists = az ad app federated-credential list --id $appId `
        --query "[?name=='$credName'] | [0].name" --output tsv
    if ([string]::IsNullOrWhiteSpace($fedExists)) {
        Write-Host "  Not found - creating."
        # Write the parameters to a temp JSON file to sidestep the notorious
        # inline-JSON quoting problems with az on Windows.
        $fedParams = @{
            name      = $credName
            issuer    = $FederatedIssuer
            subject   = $subject
            audiences = @($FederatedAudience)
        } | ConvertTo-Json
        $fedFile = Join-Path $env:TEMP "fedcred-$([guid]::NewGuid()).json"
        $fedParams | Set-Content -Path $fedFile -Encoding utf8
        try {
            az ad app federated-credential create --id $appId --parameters $fedFile --output none
        } finally {
            Remove-Item $fedFile -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "  Reusing existing federated credential."
    }
}

# --- AcrPush role assignment (re-granted every rebuild) ---------------------
# Scoped to just this registry (least privilege). Uses the SP object id +
# explicit principal type so it doesn't depend on Graph replication timing.
# NOTE: run in PowerShell, not Git Bash - Git Bash mangles the leading-slash
# --scope value into a Windows path and yields a misleading MissingSubscription.
Write-Host "Granting AcrPush on the registry to the service principal..."
az role assignment create `
    --assignee-object-id $spObjectId `
    --assignee-principal-type ServicePrincipal `
    --role AcrPush `
    --scope $acrId `
    --output none

# --- GitHub repo variables --------------------------------------------------
# These identify the SP to the azure/login action. They are NOT secrets - the
# proof of identity is the live OIDC exchange, not these ids.
Write-Host "Syncing GitHub Actions variables on '$GitHubRepo'..."
$ghAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
$ghAuthed = $false
if ($ghAvailable) {
    gh auth status 2>$null | Out-Null
    $ghAuthed = ($LASTEXITCODE -eq 0)
}
if ($ghAuthed) {
    gh variable set AZURE_CLIENT_ID           --repo $GitHubRepo --body $appId
    gh variable set AZURE_TENANT_ID           --repo $GitHubRepo --body $TenantId
    gh variable set AZURE_SUBSCRIPTION_ID     --repo $GitHubRepo --body $SubscriptionId
    gh variable set AZURE_RESOURCE_GROUP      --repo $GitHubRepo --body $ResourceGroupName
    gh variable set ACR_NAME                  --repo $GitHubRepo --body $AcrName
    gh variable set CONTAINERAPP_DEV_NAME     --repo $GitHubRepo --body $ContainerAppDevName
    gh variable set CONTAINERAPP_PROD_NAME    --repo $GitHubRepo --body $ContainerAppProdName
    Write-Host "  Variables set."
} else {
    Write-Warning "GitHub CLI not available or not logged in - skipping variable sync."
    Write-Host   "  Set these repo variables manually on $GitHubRepo :"
    Write-Host   "    AZURE_CLIENT_ID        = $appId"
    Write-Host   "    AZURE_TENANT_ID        = $TenantId"
    Write-Host   "    AZURE_SUBSCRIPTION_ID  = $SubscriptionId"
    Write-Host   "    AZURE_RESOURCE_GROUP   = $ResourceGroupName"
    Write-Host   "    ACR_NAME               = $AcrName"
    Write-Host   "    CONTAINERAPP_DEV_NAME  = $ContainerAppDevName"
    Write-Host   "    CONTAINERAPP_PROD_NAME = $ContainerAppProdName"
}

# --- Summary ----------------------------------------------------------------
$devUrl  = az containerapp show --name $ContainerAppDevName  --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn --output tsv
$prodUrl = az containerapp show --name $ContainerAppProdName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn --output tsv
Write-Host ""
Write-Host "Done. Environment is up and GitHub Actions can authenticate + push."
Write-Host "  Login server: $AcrName.azurecr.io"
Write-Host "  Client ID:    $appId"
Write-Host "  Log in locally with:  az acr login --name $AcrName"
Write-Host ""
Write-Host "  Dev app:  https://$devUrl"
Write-Host "  Prod app: https://$prodUrl"
Write-Host "  Deploy a real image with, e.g.:"
Write-Host "    az containerapp update --name $ContainerAppDevName --resource-group $ResourceGroupName --image $AcrName.azurecr.io/helloazure:<tag>"
