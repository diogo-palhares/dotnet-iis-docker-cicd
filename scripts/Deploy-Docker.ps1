#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the Customer Spike Docker image on the local Docker engine (Step 6).

.DESCRIPTION
    Idempotent: pulls the image, replaces any container with the same name, starts it and waits for /health.
    With -HelloWorld it runs the official hello-world image instead (fallback when the image is not published).

.EXAMPLE
    .\Deploy-Docker.ps1
    .\Deploy-Docker.ps1 -Image ghcr.io/diogo-palhares/dotnet-iis-docker-cicd/web:1.0.7 -HostPort 9090
    .\Deploy-Docker.ps1 -HelloWorld
#>
[CmdletBinding()]
param(
    [string]$Image = 'ghcr.io/diogo-palhares/dotnet-iis-docker-cicd/web:latest',
    [string]$ContainerName = 'customer-spike-web',

    [ValidateRange(1, 65535)]
    [int]$HostPort = 8081,

    [switch]$HelloWorld
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# docker writes progress ("Pulling...", "Unable to find image...") to stderr. In Windows PowerShell 5.1 native stderr
# becomes a terminating error under $ErrorActionPreference = 'Stop', so the native calls run with 'Continue'
# and success is decided by the exit code only.
function Invoke-Docker {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @args 2>&1 | ForEach-Object { "$_" } | Out-Host
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        throw "'docker $($args -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

# Same, but returns stdout (stderr discarded). The caller checks $LASTEXITCODE.
function Get-DockerOutput {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @args 2>$null
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI not found. Install Docker Desktop (or Docker Engine) first.'
}
$null = Get-DockerOutput info --format '{{.ServerVersion}}'
if ($LASTEXITCODE -ne 0) {
    throw 'The Docker engine is not running. Start Docker Desktop and try again.'
}

if ($HelloWorld) {
    Write-Host '==> Running the official hello-world image' -ForegroundColor Cyan
    Invoke-Docker run --rm hello-world
    return
}

Write-Host "==> Pulling $Image" -ForegroundColor Cyan
Invoke-Docker pull $Image

$existing = Get-DockerOutput ps -a --filter "name=^/$ContainerName$" --format '{{.ID}}'
if ($existing) {
    Write-Host "==> Removing the existing container '$ContainerName'" -ForegroundColor Cyan
    Invoke-Docker rm -f $ContainerName
}

Write-Host "==> Starting '$ContainerName' on http://localhost:$HostPort" -ForegroundColor Cyan
# The image listens on 8080 inside the container (ASPNETCORE_HTTP_PORTS default of the .NET 8 images).
Invoke-Docker run -d --name $ContainerName --restart unless-stopped -p "${HostPort}:8080" $Image

$url = "http://localhost:$HostPort/health"
$ok = $false
for ($attempt = 1; $attempt -le 15 -and -not $ok; $attempt++) {
    try {
        $ok = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200
    }
    catch {
        Start-Sleep -Seconds 1
    }
}

if (-not $ok) {
    Invoke-Docker logs --tail 50 $ContainerName
    throw "Smoke test failed: $url did not return 200."
}

Write-Host ''
Write-Host 'Deployment complete.' -ForegroundColor Green
Write-Host "  App    : http://localhost:$HostPort/"
Write-Host "  Health : $url"
Write-Host "  Logs   : docker logs -f $ContainerName"
