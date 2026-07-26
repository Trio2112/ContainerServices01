# Federated Identity: How GitHub Actions Authenticates to Azure

Reference note for personal review and for explaining the security model to others.
Describes how this app (ContainerServices01) lets GitHub Actions push images to
Azure Container Registry **without storing any secret**.

---

## The problem being solved

GitHub Actions needs to push Docker images to `acrhelloazure01.azurecr.io`. To do
that it must authenticate to Azure. The question is: *what does it authenticate as,
and how does it prove that identity?*

The old answer was a stored password (a client secret or the ACR admin password).
The modern answer — used here — is **Workload Identity Federation**, where no secret
exists at all.

---

## Service principal — the identity for software

When a human runs `az login`, Azure AD (Entra ID) authenticates a **user**. Software
can't do that, so it needs its own identity: a **service principal (SP)**.

There are actually two related objects:

- **App Registration** — the *definition* of the application. Has a **Client ID**
  (a.k.a. App ID). Think of it as the blueprint.
- **Service Principal** — the *instance* of that app inside your tenant. This is the
  thing that RBAC roles get assigned to. Think of it as the running identity.

The SP gets Azure RBAC roles assigned to it exactly like a user would — in our case a
single `AcrPush` role, scoped to just the one registry.

---

## Two ways an SP can prove who it is

### 1. Client secret (the old way — NOT used here)

Azure AD generates a password for the SP. You store it as a GitHub Actions secret and
log in with it. Downsides:

- It's a long-lived bearer credential — anyone who obtains it can authenticate as the
  SP from anywhere, with no additional checks.
- It expires (~2 years by default) and must be rotated.
- If it leaks (a log, a fork, a screen-share) it's compromised until you notice and
  manually revoke it.

### 2. Federated credential / Workload Identity Federation (what we use)

**No secret exists.** Instead, Azure AD is configured to *trust GitHub's OIDC token
issuer*, but only under a narrow, specific condition that we define.

---

## How the federated flow actually works

Picture Azure AD saying: *"I'll trust a login token, but only if GitHub issued it,
only if it's about this exact repo and branch, and only if it's fresh."*

1. A GitHub Actions job asks GitHub's own token service
   (`token.actions.githubusercontent.com`) for a short-lived **OIDC token**. This
   requires `permissions: id-token: write` in the workflow.
2. That token carries claims:
   - `iss` — the issuer (GitHub's token service)
   - `sub` — the subject, e.g. `repo:Trio2112/ContainerServices01:ref:refs/heads/main`
   - `aud` — the intended audience (`api://AzureADTokenExchange`)
3. The workflow hands the token to Azure AD (via the `azure/login` action) and says
   "exchange this for an Azure access token."
4. Azure AD checks: does this App Registration have a **federated credential** whose
   issuer + subject + audience match the token's claims? If **yes**, it issues a
   normal short-lived Azure access token. If **no**, the exchange fails and nothing is
   issued.
5. The workflow now holds a real but short-lived (minutes) Azure token and can run
   `az acr login`, `docker push`, etc. as the service principal.

Nothing is persisted. Nothing to rotate. Nothing to leak.

**The `sub` claim match is the actual security boundary.** Because our federated
credential's subject is pinned to `...:ref:refs/heads/main`, a token minted for a
different repo, a different branch, or a pull request simply won't match — and the
token exchange fails. The proof of identity is "GitHub's runner is genuinely executing
*this* repo's *main* branch workflow right now," which is much stronger and much
harder to steal than a static password.

---

## What's configured for THIS app

None of these values are secrets — they are identifiers (they say *who*, not *prove
it*). The proof is the live OIDC handshake, so it's fine that they live in this repo.

| Thing | Value |
|---|---|
| App Registration name | `gh-actions-containerservices01` |
| Client ID (App ID) | `a93a5076-6f27-4814-a0ba-705be24252ec` |
| SP object ID | `266996a7-63b6-4bb6-8965-89e49cc4e6b0` |
| Tenant ID | `fd5071eb-974d-4235-a862-57d706158417` |
| Subscription ID | `886e7c6f-17ce-478a-852d-c67937691146` |
| Federated credential names | `gh-main-branch`, `gh-develop-branch` |
| Trusted issuer | `https://token.actions.githubusercontent.com` |
| Trusted subjects | `repo:Trio2112/ContainerServices01:ref:refs/heads/main` (→ prod), `repo:Trio2112/ContainerServices01:ref:refs/heads/develop` (→ dev) |
| Audience | `api://AzureADTokenExchange` |
| Roles granted | `AcrPush` on the registry; `Container Apps Contributor` on `helloazure-dev` and `helloazure-prod` individually |
| Role scopes | each resource individually (not the resource group or subscription) |

**Gotcha:** without the `Container Apps Contributor` grants, `az containerapp update`
in the workflow fails with `ERROR: The containerapp 'helloazure-dev' does not exist` -
which looks like a missing-resource problem but is actually a missing-permission one.
ARM returns 404 rather than 403 when a principal has zero role assignments on a
resource, so it doesn't confirm the resource's existence to an unauthorized caller.
If a future `az containerapp update`/`create`/`delete` call from CI reports a resource
"doesn't exist" that you can otherwise see and reach, check role assignments first.

### The CLI commands that created it

```bash
# 1. App registration + service principal
az ad app create --display-name "gh-actions-containerservices01"
az ad sp create --id <appId-from-above>

# 2. Federated credential — binds trust to a specific GitHub context.
#    One of these per trusted branch (main -> prod, develop -> dev).
az ad app federated-credential create --id <appId> --parameters '{
  "name": "gh-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:Trio2112/ContainerServices01:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
az ad app federated-credential create --id <appId> --parameters '{
  "name": "gh-develop-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:Trio2112/ContainerServices01:ref:refs/heads/develop",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 3. Least-privilege role assignment, scoped to the ACR resource only
az role assignment create `
  --assignee-object-id <spObjectId> `
  --assignee-principal-type ServicePrincipal `
  --role AcrPush `
  --scope <full-resource-id-of-the-ACR>
```

> **Gotcha:** the role-assignment command must be run in **PowerShell, not Git Bash**.
> Git Bash rewrites any argument starting with `/` (like the `/subscriptions/...`
> scope) into a Windows path, which corrupts the request and produces a misleading
> `MissingSubscription` error.

---

## How the workflow consumes it

```yaml
permissions:
  id-token: write   # REQUIRED — lets the job request a GitHub OIDC token
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id:       ${{ vars.AZURE_CLIENT_ID }}       # the App ID above
      tenant-id:       ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  - run: az acr login --name acrhelloazure01
  # ...then docker build / docker push
```

`client-id`, `tenant-id`, and `subscription-id` are stored as GitHub **variables**
(not secrets) because they only identify the SP; they don't authenticate it. The
authentication is the OIDC exchange.

This is also why the ACR was created with `--admin-enabled false`: the ACR admin
username/password is exactly the shared static secret this whole mechanism exists to
avoid.

---

## Things to remember when changing this

- **The subject must match exactly** — there are no wildcards. This is why `develop`
  needed its own federated credential (`gh-develop-branch`) alongside `main`'s — a
  token minted for `refs/heads/develop` doesn't match a credential pinned to
  `refs/heads/main`. The same applies to pull requests: to trust those too, add
  another credential with subject `repo:Trio2112/ContainerServices01:pull_request`.
- **Federated credentials, the app, and the SP live in Azure AD, not in the resource
  group.** Tearing down the resource group does NOT delete them.
- **The role assignment IS tied to the ACR's resource ID.** When the ACR is deleted
  and recreated during a teardown/standup cycle, the role assignment is lost and must
  be recreated against the new registry.
