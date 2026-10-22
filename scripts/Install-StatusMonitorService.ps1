#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Customer Spike status monitor as a Windows service (Step 4).

.DESCRIPTION
    Idempotent: an existing service with the same name is stopped and replaced.

      1. Copies the published executable to the install folder (the status.log file is preserved)
      2. Creates the service pointing at the .exe, running as the given user
      3. Sets the startup type to Automatic
      4. Configures the error recovery to restart the service after 300 seconds (default)
      5. Starts the service

.PARAMETER PackagePath
    The zip produced by the CI pipeline (CustomerSpike.StatusMonitor-<version>.zip) or a published folder.

.PARAMETER Credential
    Account that runs the service. For a local account use 'name' or '.\name'.

.PARAMETER MonitorUrl
    Optional. Overrides StatusMonitor:Url in the installed appsettings.json.

.EXAMPLE
    .\Install-StatusMonitorService.ps1 -PackagePath .\CustomerSpike.StatusMonitor-1.0.1.zip -Credential (Get-Credential svc-customerspike)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,

    [Parameter(Mandatory)]
    [pscredential]$Credential,

    [string]$ServiceName = 'CustomerSpikeStatusMonitor',
    [string]$InstallPath = 'C:\Services\CustomerSpikeStatusMonitor',

    [ValidateRange(1, 86400)]
    [int]$RestartDelaySeconds = 300,

    [string]$MonitorUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# New-Service does not grant the "Log on as a service" right to the account, so do it explicitly.
function Grant-LogOnAsServiceRight {
    param([string]$Sid)

    $work = Join-Path ([IO.Path]::GetTempPath()) ('secedit-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $exported = Join-Path $work 'export.inf'
        $modified = Join-Path $work 'import.inf'
        $database = Join-Path $work 'secedit.sdb'

        secedit.exe /export /cfg $exported /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit /export failed (exit code $LASTEXITCODE)." }

        $result = @()
        $found = $false
        foreach ($line in (Get-Content -Path $exported -Encoding Unicode)) {
            if ($line -match '^SeServiceLogonRight\s*=\s*(.*)$') {
                $found = $true
                if ($Matches[1] -match [regex]::Escape($Sid)) {
                    Write-Host '    Account already has the "Log on as a service" right.'
                    return
                }
                $result += "SeServiceLogonRight = $($Matches[1]),*$Sid"
            }
            else {
                $result += $line
            }
        }
        if (-not $found) {
            $result += 'SeServiceLogonRight = *' + $Sid
        }

        Set-Content -Path $modified -Value $result -Encoding Unicode
        secedit.exe /configure /db $database /cfg $modified /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit /configure failed (exit code $LASTEXITCODE)." }
        Write-Host '    Granted the "Log on as a service" right.'
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- prerequisites
Write-Step 'Checking prerequisites'
if (-not (Test-Path $PackagePath)) {
    throw "Package '$PackagePath' was not found."
}

$userName = $Credential.UserName -replace '^(\.|' + [regex]::Escape($env:COMPUTERNAME) + ')\\', ''
$isLocal = $userName -notmatch '[\\@]'
$account = if ($isLocal) { "$env:COMPUTERNAME\$userName" } else { $userName }
if ($isLocal -and -not (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue)) {
    throw "Local user '$userName' does not exist. Create it first (Deploy-IIS.ps1 creates it) or pass another account."
}
$sid = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value

# ------------------------------------------------------- remove previous version
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Removing the existing service '$ServiceName'"
    if ($existing.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    sc.exe delete $ServiceName | Out-Null
    for ($i = 0; $i -lt 30 -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 500
    }
}

# --------------------------------------------------------------------- binaries
Write-Step "Copying the binaries to '$InstallPath'"
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
Get-ChildItem -Path $InstallPath -Force | Where-Object { $_.Name -ne 'status.log' } | Remove-Item -Recurse -Force
if ((Get-Item $PackagePath).PSIsContainer) {
    Copy-Item -Path (Join-Path $PackagePath '*') -Destination $InstallPath -Recurse -Force
}
else {
    Expand-Archive -Path $PackagePath -DestinationPath $InstallPath -Force
}

$exe = Join-Path $InstallPath 'CustomerSpike.StatusMonitor.exe'
if (-not (Test-Path $exe)) {
    throw "'$exe' was not found: the package does not look like a StatusMonitor publish output."
}

if ($MonitorUrl) {
    $settingsPath = Join-Path $InstallPath 'appsettings.json'
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    $settings.StatusMonitor.Url = $MonitorUrl
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "    StatusMonitor:Url set to $MonitorUrl"
}

# The service writes status.log next to the executable, so the account needs write access there.
icacls.exe $InstallPath /grant "${account}:(OI)(CI)M" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed for '$InstallPath' (exit code $LASTEXITCODE)." }

# ---------------------------------------------------------------------- service
Write-Step "Creating the service '$ServiceName' (account: $account, startup: Automatic)"
Grant-LogOnAsServiceRight -Sid $sid

$serviceCredential = New-Object System.Management.Automation.PSCredential($account, $Credential.Password)
New-Service -Name $ServiceName `
    -BinaryPathName "`"$exe`"" `
    -DisplayName 'Customer Spike Status Monitor' `
    -Description 'Checks the Customer Spike IIS site every 60 seconds and logs the HTTP status.' `
    -StartupType Automatic `
    -Credential $serviceCredential | Out-Null

Write-Step "Configuring the error recovery (restart after $RestartDelaySeconds seconds)"
$delayMs = $RestartDelaySeconds * 1000
# sc.exe, not 'sc': in PowerShell 'sc' is an alias of Set-Content.
sc.exe failure $ServiceName reset= 86400 actions= "restart/$delayMs/restart/$delayMs/restart/$delayMs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "sc.exe failure failed (exit code $LASTEXITCODE)." }
# Also treat a stop with a non-zero exit code as a failure (the monitor itself exits with code 1).
sc.exe failureflag $ServiceName 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "sc.exe failureflag failed (exit code $LASTEXITCODE)." }

Write-Step 'Starting the service'
Start-Service -Name $ServiceName
Start-Sleep -Seconds 3

Get-Service -Name $ServiceName | Format-Table Name, Status, StartType -AutoSize
sc.exe qfailure $ServiceName

$logFile = Join-Path $InstallPath 'status.log'
if (Test-Path $logFile) {
    Write-Host 'Latest log lines:'
    Get-Content -Path $logFile -Tail 3
}
