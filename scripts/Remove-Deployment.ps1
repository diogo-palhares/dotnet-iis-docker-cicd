#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes everything created by Deploy-IIS.ps1 and Install-StatusMonitorService.ps1.

.DESCRIPTION
    Handy to repeat the demonstration from a clean state. Pass -RemoveUser to also delete the local account.
#>
[CmdletBinding()]
param(
    [string]$SiteName = 'CustomerSpike',
    [string]$SiteRoot = 'C:\inetpub\CustomerSpike',
    [string]$AppPoolName = 'CustomerSpikePool',
    [string]$GroupName = 'CustomerSpikeUsers',
    [int]$HttpsPort = 8443,
    [string]$LogDirectory = 'C:\inetpub\logs\CustomerSpike',
    [string]$ServiceName = 'CustomerSpikeStatusMonitor',
    [string]$InstallPath = 'C:\Services\CustomerSpikeStatusMonitor',
    [string]$UserName,
    [switch]$RemoveUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-FolderWithRetry {
    param([string]$Path)
    # A process (e.g. the IIS worker w3wp.exe) can take a moment to release its files after stopping.
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if (-not (Test-Path $Path)) { return }
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Could not remove '$Path'; a process is still using it."
}

Write-Host "==> Windows service '$ServiceName'" -ForegroundColor Cyan
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
}
if (Test-Path $InstallPath) { Remove-FolderWithRetry -Path $InstallPath }

Write-Host "==> IIS site '$SiteName' and pool '$AppPoolName'" -ForegroundColor Cyan
if (Get-Module -ListAvailable -Name WebAdministration) {
    Import-Module WebAdministration
    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
            Stop-WebAppPool -Name $AppPoolName
            while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') { Start-Sleep -Milliseconds 200 }
        }
    }
    if (Test-Path "IIS:\Sites\$SiteName") { Remove-Website -Name $SiteName }
    if (Test-Path "IIS:\AppPools\$AppPoolName") { Remove-WebAppPool -Name $AppPoolName }
    if (Test-Path "IIS:\SslBindings\0.0.0.0!$HttpsPort") { Remove-Item "IIS:\SslBindings\0.0.0.0!$HttpsPort" -Force }
}
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -like "$SiteName self-signed*" } | Remove-Item
foreach ($path in $SiteRoot, $LogDirectory) {
    if (Test-Path $path) { Remove-FolderWithRetry -Path $path }
}

Write-Host "==> Local group '$GroupName'" -ForegroundColor Cyan
if (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue) { Remove-LocalGroup -Name $GroupName }

if ($RemoveUser) {
    if (-not $UserName) { throw '-UserName is required with -RemoveUser.' }
    Write-Host "==> Local user '$UserName'" -ForegroundColor Cyan
    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $UserName }
}

Write-Host 'Clean-up complete.' -ForegroundColor Green
