# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run locally (http://localhost:5073)
dotnet run --project src/HelloAzure

# Build (Release)
dotnet build src/HelloAzure/HelloAzure.csproj -c Release

# Build Docker image (BUILD_NUMBER is optional; defaults to "local-dev")
docker build -t helloazure:local --build-arg BUILD_NUMBER=1 .

# Run Docker container
docker run --rm -p 8080:8080 helloazure:local
```

There are no automated tests in this project yet.

## Architecture

Single ASP.NET Core Razor Pages app (`src/HelloAzure/`) inside a solution (`ContainerServices01.slnx`).

**Build number** flows as a Docker build arg (`--build-arg BUILD_NUMBER=...`) → `ENV BUILD_NUMBER` in the runtime image → read by `IndexModel` via `IConfiguration["BUILD_NUMBER"]`, falling back to `"local-dev"` when not set. This pattern is ready for GitHub Actions to inject the CI build number.

**Error logging**: `IndexModel.OnPostLogError` explicitly calls `ILogger.LogError` before throwing — so the error appears twice in logs: once as the intentional log entry and once as the unhandled exception. This is by design for Azure log inspection practice.

**Container**: Multi-stage Dockerfile (sdk:10.0 build → aspnet:10.0 runtime). The aspnet base image runs as non-root and listens on port 8080 (`ASPNETCORE_HTTP_PORTS=8080` default).

**Planned work**: Azure Web Apps hosting, Azure Container Registry, Azure Container Services, GitHub Actions CI/CD for dev/prod environments, image tagging, and Azure log inspection. None of this is implemented yet.
