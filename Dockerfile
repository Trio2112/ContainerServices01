# --- Build stage ---
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore dependencies first (layer-cache friendly)
COPY src/HelloAzure/HelloAzure.csproj src/HelloAzure/
RUN dotnet restore src/HelloAzure/HelloAzure.csproj

# Copy the rest of the source and publish
COPY src/ src/
RUN dotnet publish src/HelloAzure/HelloAzure.csproj -c Release -o /app/publish --no-restore

# --- Runtime stage ---
FROM mcr.microsoft.com/dotnet/aspnet:10.0

# BUILD_NUMBER is injected at docker build time via --build-arg; falls back to "local-dev"
ARG BUILD_NUMBER=local-dev
ENV BUILD_NUMBER=$BUILD_NUMBER

# aspnet image defaults to port 8080 and non-root user
WORKDIR /app
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "HelloAzure.dll"]
