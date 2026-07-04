# Architecture & CI/CD Notes

Reference document for personal review and AI agent context when building the CI/CD pipeline and Azure infrastructure.

---

## Razor Pages vs MVC — Code Walkthrough

### The Big Mental Shift: Pages Instead of Controllers

In MVC, a request maps to a **Controller → Action → View**. The controller and view are in different folders and linked by convention.

In Razor Pages, the controller and view are **merged into a single unit** — a `.cshtml` file (the view) and its paired `.cshtml.cs` file (the "page model", which is your controller). They live together in the `Pages/` folder. There are no separate controller classes.

---

### `Program.cs` — Startup

```csharp
builder.Services.AddRazorPages();       // registers Razor Pages (replaces AddControllersWithViews)
app.MapRazorPages().WithStaticAssets(); // maps URL routes to Pages/ (replaces MapControllerRoute)
```

Razor Pages uses the **file system** as the route. `Pages/Index.cshtml` → `/`, `Pages/Privacy.cshtml` → `/Privacy`. No routing attributes or `routes.MapRoute(...)` needed.

---

### `Pages/Index.cshtml.cs` — The Page Model (your Controller)

```csharp
public class IndexModel : PageModel   // PageModel = base class, like Controller
```

Instead of action methods, you write **handler methods** named by HTTP verb:

| MVC | Razor Pages |
|---|---|
| `public IActionResult Index()` | `public void OnGet()` |
| `[HttpPost] public IActionResult Submit()` | `public IActionResult OnPost()` |

The `OnGet()` sets two **public properties** on the model:

```csharp
public string BuildNumber { get; private set; } = string.Empty;
public DateTime CurrentTime { get; private set; }

public void OnGet()
{
    BuildNumber = _configuration["BUILD_NUMBER"] ?? "local-dev";
    CurrentTime = DateTime.Now;
}
```

Those public properties are how data flows to the view — there's no `return View(model)` and no `ViewBag`. The page model *is* the model, and the view accesses it directly via `@Model.BuildNumber`.

`OnPostLogError()` is a **named handler** — covered below.

Dependency injection works identically to MVC — constructor injection, same DI container.

---

### `Pages/Index.cshtml` — The View

```cshtml
@page               // THIS is what makes it a Razor Page (not an MVC view)
@model IndexModel   // binds this view to its page model class
```

`@page` is the key difference from an MVC `.cshtml` view. It tells the framework this file handles requests directly rather than being rendered by a controller action.

Data access is the same Razor syntax:

```cshtml
@Model.CurrentTime.ToString("yyyy-MM-dd HH:mm:ss")
@Model.BuildNumber
```

#### Named handlers and the form

```cshtml
<form method="post" asp-page-handler="LogError">
```

`asp-page-handler="LogError"` is a Tag Helper (replaces `@Html.BeginForm()`). It tells ASP.NET to POST to the handler method named `OnPost**LogError**()` on the page model. The framework appends `?handler=LogError` to the form's action URL automatically.

This is the Razor Pages equivalent of having a separate `[HttpPost]` action in MVC — but scoped to a single page.

---

### `Pages/Shared/_Layout.cshtml` — Shared Layout

Identical in concept to MVC's `_Layout.cshtml`. `@RenderBody()` is where page content is injected.

```cshtml
asp-page="/Index"   // Tag Helper equivalent of @Html.ActionLink / @Url.Action
```

Tag Helpers like `asp-page`, `asp-page-handler`, and `asp-append-version` replace HTML helpers. They look like HTML attributes rather than inline C# method calls.

---

### `Pages/_ViewImports.cshtml` and `_ViewStart.cshtml`

Identical in purpose to MVC:
- `_ViewImports.cshtml` — global `@using`, `@namespace`, and `@addTagHelper` declarations. `@addTagHelper *, Microsoft.AspNetCore.Mvc.TagHelpers` enables all built-in `asp-*` Tag Helpers globally.
- `_ViewStart.cshtml` — sets `Layout = "_Layout"` for every page, so individual pages don't have to.

---

### `appsettings.json` — Configuration

`IConfiguration` injected into the page model reads from `appsettings.json`, environment variables, and Docker `ENV` values. The `BUILD_NUMBER` the app reads comes from the Docker `ENV BUILD_NUMBER` set at container build time — the configuration system merges environment variables automatically, so it doesn't need to appear in `appsettings.json`.

---

### MVC → Razor Pages Cheat Sheet

| MVC concept | Razor Pages equivalent |
|---|---|
| `Controllers/HomeController.cs` | `Pages/Index.cshtml.cs` (page model) |
| `public IActionResult Index()` | `public void OnGet()` |
| `[HttpPost] public IActionResult Foo()` | `public IActionResult OnPostFoo()` |
| `return View(model)` | Set public properties on page model |
| `@Html.ActionLink(...)` | `<a asp-page="/Index">` |
| `@Html.BeginForm(...)` | `<form asp-page-handler="Foo">` |
| `ViewBag.Title` | `ViewData["Title"]` (same, actually) |
| `MapControllerRoute(...)` | `MapRazorPages()` — file system is the route |

---

## CI/CD Plan: GitHub Actions + Azure Container Registry

### How BUILD_NUMBER Gets Automated

Currently `BUILD_NUMBER` is supplied manually via `--build-arg BUILD_NUMBER=1`. In GitHub Actions, the built-in variable `github.run_number` increments automatically on every workflow run and replaces the manual step.

### Workflow Pattern

```yaml
env:
  ACR: myregistry.azurecr.io
  IMAGE: helloazure
  BUILD: ${{ github.run_number }}

steps:
  - name: Build and push to ACR
    run: |
      docker build --build-arg BUILD_NUMBER=${{ env.BUILD }} -t ${{ env.ACR }}/${{ env.IMAGE }}:${{ env.BUILD }} .
      docker push ${{ env.ACR }}/${{ env.IMAGE }}:${{ env.BUILD }}

  - name: Deploy to dev
    run: az containerapp update --name helloazure-dev --image ${{ env.ACR }}/${{ env.IMAGE }}:${{ env.BUILD }}
```

### Tagging Strategy

The image tag and the build number are the **same value**, giving direct 1-to-1 traceability between what GitHub ran and what's deployed.

If GitHub Actions run #42 fires:
- The app inside the container displays `Build number: 42`
- The image in ACR is tagged `myregistry.azurecr.io/helloazure:42`
- Dev or prod is explicitly told to run `:42`

**Never deploy `:latest`** — always deploy a pinned, explicit tag. Some teams also push a `:latest` tag in parallel as a convenience for local pulls, but deployments use the explicit number.

### Rollback

Because every build is a pinned tag that remains in ACR, rolling back is simply redeploying the previous tag:

```bash
az containerapp update --name helloazure-dev --image myregistry.azurecr.io/helloazure:41
```

### Dev vs. Prod Environments

Two workflow jobs (or two workflow files):
- **Dev**: triggers on every push to `main`. Deploys the new tag automatically.
- **Prod**: triggers on a tagged release (e.g. `v1.0.0`). Deploys the same image tag that was validated in dev.

Both pass `github.run_number` as the build number. The Dockerfile requires no changes — the `ARG`/`ENV` pattern already supports this.

### Infrastructure Still to Build

- Azure Container Registry (ACR)
- Azure Web App or Azure Container Apps environment (dev + prod)
- GitHub Actions workflow files (`.github/workflows/`)
- Service principal or managed identity for GitHub Actions → Azure auth
- ACR credentials stored as GitHub Actions secrets
