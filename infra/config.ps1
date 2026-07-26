# Shared settings for the infra scripts in this folder.
# standup.ps1 and teardown.ps1 both dot-source this file so names can never
# drift between "create" and "delete".

# --- Azure subscription context ---
# Pinned explicitly so the scripts always target the right subscription even
# if your CLI's default context is pointing somewhere else.
$SubscriptionId = "886e7c6f-17ce-478a-852d-c67937691146"
$TenantId       = "fd5071eb-974d-4235-a862-57d706158417"

# --- Resource group + registry (destroyed on teardown) ---
$ResourceGroupName = "rg-containerservices01"
$Location          = "centralus"
$AcrName           = "acrhelloazure01"
$AcrSku            = "Basic"

# --- Container Apps hosting (destroyed on teardown, same as the RG above) ---
# One environment hosts both the dev and prod apps - cheaper than two
# environments, and dev/prod isolation is achieved via separate container apps
# rather than separate environments.
$LogAnalyticsName      = "law-helloazure01"
$ContainerAppsEnvName  = "cae-helloazure01"
$ContainerAppDevName   = "helloazure-dev"
$ContainerAppProdName  = "helloazure-prod"
$ContainerAppTargetPort = 8080
# Public placeholder image used only at first creation, before GitHub Actions
# has ever pushed a real image to ACR. CI overwrites this via
# `az containerapp update --image ...` on the first successful deploy.
# Must listen on $ContainerAppTargetPort or ingress will time out waiting for
# a response - this .NET 8+ ASP.NET sample defaults to 8080, same as our own
# app's Dockerfile, unlike the more commonly-referenced
# mcr.microsoft.com/azuredocs/containerapps-helloworld (which listens on 80).
$PlaceholderImage      = "mcr.microsoft.com/dotnet/samples:aspnetapp"

# --- GitHub Actions federated identity (Azure AD objects survive teardown) ---
$AppDisplayName           = "gh-actions-containerservices01"
$GitHubRepo               = "Trio2112/ContainerServices01"
$FederatedIssuer          = "https://token.actions.githubusercontent.com"
$FederatedAudience        = "api://AzureADTokenExchange"
# One federated credential per branch that's allowed to authenticate as this
# identity - main deploys to prod, develop deploys to dev. A push from any
# other branch (or a PR) has no matching credential, so the OIDC exchange
# simply fails rather than being trusted.
$TrustedBranches          = @("main", "develop")
