# Customer Spike - .NET CI/CD and deployment automation

Spike of a customer management application plus the build, packaging and deployment tooling around it:

| Component | What it is |
|---|---|
| `src/CustomerSpike.Web` | ASP.NET Core 8 minimal API + a single page (form + grid) to enter and list customers. Data is kept in memory (spike). |
| `src/CustomerSpike.StatusMonitor` | .NET 8 Worker Service / Windows service that probes the site every 60 s and logs the HTTP status. |
| `tests/CustomerSpike.Web.Tests` | xUnit integration tests (`WebApplicationFactory`). |
| `.github/workflows/ci.yml` | CI: format check, build, test, zip packages, Docker image. |
| `scripts/` | PowerShell deployment scripts for IIS, the Windows service and Docker. |

## Pipeline stages and where to find them

| Step | Deliverable |
|---|---|
| 1. Build | `src/CustomerSpike.Web` + [`ci.yml`](.github/workflows/ci.yml), job **build** (triggers on every push / PR, produces the zip packages) |
| 2. IIS deployment | [`scripts/Deploy-IIS.ps1`](scripts/Deploy-IIS.ps1) |
| 3. Log status | `src/CustomerSpike.StatusMonitor` |
| 4. Windows service deployment | [`scripts/Install-StatusMonitorService.ps1`](scripts/Install-StatusMonitorService.ps1) |
| 5. Docker image | [`Dockerfile`](Dockerfile) + [`ci.yml`](.github/workflows/ci.yml), job **docker** (pushes to GitHub Container Registry) |
| 6. Docker deployment | [`scripts/Deploy-Docker.ps1`](scripts/Deploy-Docker.ps1) |

## Prerequisites (Windows 10/11 or Server)

- .NET 8 SDK (to build / run from the IDE) - `winget install Microsoft.DotNet.SDK.8`
- IIS with the management scripting tools, and the **ASP.NET Core Hosting Bundle 8** (needed by IIS to host .NET apps):
  ```powershell
  # elevated PowerShell
  Enable-WindowsOptionalFeature -Online -All -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-ManagementConsole,IIS-ManagementScriptingTools
  winget install Microsoft.DotNet.HostingBundle.8
  ```
- Docker Desktop (steps 5-6 only)
- Open the folder in VS Code, or `CustomerSpike.sln` in Visual Studio 2022.

## Run it locally (IDE or CLI)

```powershell
dotnet test                                        # 7 tests
dotnet run --project src/CustomerSpike.Web         # web app, URL printed on start-up
dotnet run --project src/CustomerSpike.StatusMonitor   # monitor (console mode)
```

The monitor reads `StatusMonitor:*` from its `appsettings.json` (URL, interval, log file name). Run from the IDE it
writes `status.log` next to the executable and exits with code 1 as soon as the status is not 200.

## Full walkthrough on a Windows machine

All deployment scripts need an **elevated** PowerShell (they have `#Requires -RunAsAdministrator`).

```powershell
# 1. Get the packages: download the "packages-<version>" artifact from the latest CI run, or build them locally
dotnet publish src/CustomerSpike.Web -c Release -o publish/web
dotnet publish src/CustomerSpike.StatusMonitor -c Release -r win-x64 --self-contained false -o publish/monitor

# 2. IIS: site (http 8080 + https 8443), local group, app pool identity, custom log folder, /customers application
$cred = Get-Credential svc-customerspike          # local account; created if it does not exist
.\scripts\Deploy-IIS.ps1 -PackagePath .\publish\web -Credential $cred
#    -> http://localhost:8080/customers/       https://localhost:8443/customers/ (self-signed)

# 3. Windows service: auto-start, runs as the same account, restarts 300 s after a failure
.\scripts\Install-StatusMonitorService.ps1 -PackagePath .\publish\monitor -Credential $cred
Get-Content C:\Services\CustomerSpikeStatusMonitor\status.log -Wait

# 4. Docker (optional)
.\scripts\Deploy-Docker.ps1            # pulls the image published by CI and runs it on http://localhost:8081
.\scripts\Deploy-Docker.ps1 -HelloWorld   # fallback: official hello-world image

# Start over
.\scripts\Remove-Deployment.ps1 -RemoveUser -UserName svc-customerspike
```

`-PackagePath` accepts either the CI zip or an already published folder.

### Demonstrating the "stop and recover" behaviour

1. Stop the pool: `Stop-WebAppPool CustomerSpikePool` (the health endpoint now answers 503).
2. Within 60 s `status.log` gets a `503` line and the service stops.
3. 300 s later the Service Control Manager restarts it (`sc.exe qfailure CustomerSpikeStatusMonitor` shows the policy).
4. Start the pool again (`Start-WebAppPool CustomerSpikePool`) before the restart to see it stay up.

## CI/CD pipeline

`ci.yml` runs on every push to `main`, on pull requests and on `v*` tags.

- **build** job: restore (cached NuGet) -> `dotnet format --verify-no-changes` -> build with warnings as errors ->
  tests (TRX uploaded) -> `dotnet publish` -> `CustomerSpike.Web-<version>.zip` and
  `CustomerSpike.StatusMonitor-<version>.zip` uploaded as the `packages-<version>` artifact.
- **docker** job: builds the multi-stage `Dockerfile`; on `main` / tags pushes
  `ghcr.io/<owner>/<repo>/web:<version>`, `:latest` and `:sha-<commit>` using the built-in `GITHUB_TOKEN` (no secrets to manage).
  On pull requests the image is built but not pushed.
- Version = `1.0.<run number>`, stamped into the assemblies and the image labels.

Best practices applied: `concurrency` cancels superseded runs, least-privilege `permissions` (write only where needed),
job timeouts, pinned `global.json` SDK, `TreatWarningsAsErrors`, Dependabot for NuGet / Actions / Docker,
non-root container user, `.gitignore` / `.dockerignore` / `.gitattributes`.

> After the first successful push, set the package visibility to **public** in GitHub (Packages -> package settings) so
> `Deploy-Docker.ps1` can pull it anonymously.

## Design notes and trade-offs

- **IIS hosting**: the application is deployed as an IIS *application* (`/customers`) below the web site, bound to its own
  application pool with *No Managed Code* (ASP.NET Core runs through the ASP.NET Core Module). The page and API use relative
  URLs and `PathBase`-aware redirects so the same build works at `/` (Docker) and at `/customers` (IIS).
- **Identity**: the pool and the service run as a dedicated local account that is member of a local group; the group - not the
  account - receives the NTFS rights (read on the site, modify on the log folder).
- **Service failure handling**: when the status is not 200 the monitor logs it and terminates the process with exit code 1.
  The service control manager counts that as a crash and applies the recovery action (`sc.exe failure ... restart/300000`);
  `failureflag` is also set so a non-zero stop is treated as a failure.
- **HTTPS**: a self-signed certificate for `localhost` is generated if none exists. For a real environment replace it with a
  certificate from the machine store (a parameter for the thumbprint would be the natural next step).
- **Secrets**: no credentials in the repository. Scripts take a `PSCredential`; the container registry login in CI uses
  `GITHUB_TOKEN`.

## Known limitations (spike)

- Customers are stored in memory and lost on restart; no authentication, no persistent database.
- Only one monitored URL; no alerting besides the log file and the service state.
- Scripts target a single local machine (no remoting / inventory).
- The container has no `HEALTHCHECK` (the aspnet base image has no curl); orchestrators should probe `/health`.
