# HelloAzure

A simple ASP.NET Core web app used as a sandbox for learning Azure services.

**Features**
- Displays "Hello World", current date/time, and build number.
- "Log Error" button throws and logs a test exception (for Azure log inspection practice).

---

## Run locally

```bash
dotnet run --project src/HelloAzure
```

Open the URL shown in the terminal (e.g. `http://localhost:5000`).

## Run in Docker

```bash
# Build — pass BUILD_NUMBER to stamp the image
docker build -t helloazure:local --build-arg BUILD_NUMBER=1 .

# Run on port 8080
docker run --rm -p 8080:8080 helloazure:local
```

Open `http://localhost:8080`.

Click **Log Error** and check the container's console output (or `docker logs <container>`) to see the logged exception.
