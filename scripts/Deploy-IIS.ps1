#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys the Customer Spike web package to IIS (Step 2).

.DESCRIPTION
    Idempotent: running it again converges the machine to the same state and re-deploys the package.

      1. Creates the local user (if missing) and a local group, and adds the user to the group
      2. Creates an application pool running as that user
      3. Creates a web site with HTTP and HTTPS bindings (self-signed certificate for 'localhost')
      4. Moves the web site log files to a custom directory
      5. Creates an application below the web site, bound to the application pool
      6. Extracts the package into the application folder and runs a smoke test

.PARAMETER PackagePath
    The zip produced by the CI pipeline (CustomerSpike.Web-<version>.zip) or an already extracted folder.

.PARAMETER Credential
    Local account that runs the application pool. Created if it does not exist.

.EXAMPLE
    .\Deploy-IIS.ps1 -PackagePath .\CustomerSpike.Web-1.0.1.zip -Credential (Get-Credential svc-customerspike)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,

    [Parameter(Mandatory)]
    [pscredential]$Credential,

    [string]$SiteName = 'CustomerSpike',
    [string]$SiteRoot = 'C:\inetpub\CustomerSpike',
    [string]$ApplicationName = 'customers',
    [string]$AppPoolName = 'CustomerSpikePool',
    [string]$GroupName = 'CustomerSpikeUsers',
    [string]$LogDirectory = 'C:\inetpub\logs\CustomerSpike',

    [ValidateRange(1, 65535)]
    [int]$HttpPort = 8080,

    [ValidateRange(1, 65535)]
    [int]$HttpsPort = 8443
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Grant-FolderAccess {
    param([string]$Path, [string]$Principal, [string]$Rights)
    icacls.exe $Path /grant "${Principal}:(OI)(CI)$Rights" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed for '$Path' (exit code $LASTEXITCODE)." }
}

function Add-MemberIfMissing {
    param([string]$Group, [string]$User)
    $isMember = Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*\$User" }
    if ($isMember) {
        Write-Host "    '$User' is already a member of '$Group'."
    }
    else {
        Add-LocalGroupMember -Group $Group -Member $User
        Write-Host "    Added '$User' to '$Group'."
    }
}

# ---------------------------------------------------------------- prerequisites
Write-Step 'Checking prerequisites'
if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    throw 'The IIS management scripting tools are not installed (feature IIS-ManagementScriptingTools).'
}
if (-not (Test-Path "$env:ProgramFiles\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll")) {
    throw 'The ASP.NET Core Hosting Bundle is not installed. Install it first (winget install Microsoft.DotNet.HostingBundle.8).'
}
if (-not (Test-Path $PackagePath)) {
    throw "Package '$PackagePath' was not found."
}
Import-Module WebAdministration

$userName = $Credential.UserName -replace '^(\.|' + [regex]::Escape($env:COMPUTERNAME) + ')\\', ''
if ($userName -match '[\\@]') {
    throw "Only local accounts are supported (got '$($Credential.UserName)')."
}
$identity = "$env:COMPUTERNAME\$userName"

# ------------------------------------------------------------ 1. user and group
Write-Step "Configuring local user '$userName' and group '$GroupName'"
if (-not (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $userName -Password $Credential.Password -PasswordNeverExpires `
        -UserMayNotChangePassword -Description 'Customer Spike application pool identity' | Out-Null
    Write-Host "    Created local user '$userName'."
}
else {
    Write-Host "    Local user '$userName' already exists (its password is left unchanged)."
}

if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $GroupName -Description 'Customer Spike application users' | Out-Null
    Write-Host "    Created local group '$GroupName'."
}
Add-MemberIfMissing -Group $GroupName -User $userName
# IIS_IUSRS gives the worker process the standard IIS rights (temp files, compilation caches...).
Add-MemberIfMissing -Group 'IIS_IUSRS' -User $userName

# ------------------------------------------------------------------ 2. app pool
Write-Step "Configuring application pool '$AppPoolName'"
$poolPath = "IIS:\AppPools\$AppPoolName"
if (-not (Test-Path $poolPath)) {
    New-WebAppPool -Name $AppPoolName | Out-Null
}
# ASP.NET Core runs out of process of the CLR hosted by IIS: the pool must have no managed runtime.
Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value ''
# IIS requires the plain-text password to store the identity; it is never written to disk by this script.
Set-ItemProperty $poolPath -Name processModel -Value @{
    identityType = 'SpecificUser'
    userName     = $identity
    password     = $Credential.GetNetworkCredential().Password
}

# ------------------------------------------------------------ package + folders
Write-Step 'Preparing folders and extracting the package'
$appFolder = Join-Path $SiteRoot $ApplicationName
New-Item -ItemType Directory -Force -Path $SiteRoot, $appFolder, $LogDirectory | Out-Null

if ((Test-Path $poolPath) -and (Get-WebAppPoolState -Name $AppPoolName).Value -eq 'Started') {
    Stop-WebAppPool -Name $AppPoolName   # release file locks before replacing the binaries
    while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') { Start-Sleep -Milliseconds 200 }
}

Get-ChildItem -Path $appFolder -Force | Remove-Item -Recurse -Force
if ((Get-Item $PackagePath).PSIsContainer) {
    Copy-Item -Path (Join-Path $PackagePath '*') -Destination $appFolder -Recurse -Force
}
else {
    Expand-Archive -Path $PackagePath -DestinationPath $appFolder -Force
}

$placeholder = Join-Path $SiteRoot 'index.html'
if (-not (Test-Path $placeholder)) {
    Set-Content -Path $placeholder -Encoding ASCII -Value "<html><body><p>Customer Spike site root. The application lives at <a href=""$ApplicationName/"">/$ApplicationName/</a>.</p></body></html>"
}

Grant-FolderAccess -Path $SiteRoot -Principal $GroupName -Rights 'RX'
Grant-FolderAccess -Path $LogDirectory -Principal $GroupName -Rights 'M'

# -------------------------------------------------------------- 3. certificate
Write-Step 'Preparing the HTTPS certificate'
$certName = "$SiteName self-signed (localhost)"
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.FriendlyName -eq $certName -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName 'localhost' -CertStoreLocation Cert:\LocalMachine\My `
        -FriendlyName $certName -NotAfter (Get-Date).AddYears(1)
    Write-Host "    Created certificate $($cert.Thumbprint)."
}
else {
    Write-Host "    Reusing certificate $($cert.Thumbprint)."
}

# ----------------------------------------------------- 3b. web site and bindings
Write-Step "Configuring web site '$SiteName' (http:$HttpPort, https:$HttpsPort)"
$siteIisPath = "IIS:\Sites\$SiteName"
if (-not (Test-Path $siteIisPath)) {
    New-Website -Name $SiteName -PhysicalPath $SiteRoot -Port $HttpPort -IPAddress '*' `
        -ApplicationPool 'DefaultAppPool' | Out-Null
}
else {
    Set-ItemProperty $siteIisPath -Name physicalPath -Value $SiteRoot
}

if (-not (Get-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort)) {
    New-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort -IPAddress '*' -SslFlags 0
}
$sslBinding = "IIS:\SslBindings\0.0.0.0!$HttpsPort"
if (Test-Path $sslBinding) { Remove-Item $sslBinding -Force }
New-Item $sslBinding -Value $cert | Out-Null

# --------------------------------------------------------------------- 4. logs
Write-Step "Moving the web site log files to '$LogDirectory'"
Set-ItemProperty $siteIisPath -Name logFile.directory -Value $LogDirectory

# ------------------------------------------------------------- 5. application
Write-Step "Configuring application '/$ApplicationName' bound to '$AppPoolName'"
$appIisPath = "$siteIisPath\$ApplicationName"
if (-not (Get-WebApplication -Site $SiteName -Name $ApplicationName)) {
    New-WebApplication -Name $ApplicationName -Site $SiteName -PhysicalPath $appFolder `
        -ApplicationPool $AppPoolName | Out-Null
}
else {
    Set-ItemProperty $appIisPath -Name physicalPath -Value $appFolder
    Set-ItemProperty $appIisPath -Name applicationPool -Value $AppPoolName
}

# ------------------------------------------------------------------ start + test
Write-Step 'Starting the application pool and web site'
Start-WebAppPool -Name $AppPoolName
if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') { Start-Website -Name $SiteName }

Write-Step 'Smoke test'
$url = "http://localhost:$HttpPort/$ApplicationName/health"
$ok = $false
for ($attempt = 1; $attempt -le 10 -and -not $ok; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
        $ok = $response.StatusCode -eq 200
    }
    catch {
        Start-Sleep -Seconds 2   # the first request starts the worker process
    }
}
if (-not $ok) {
    throw "Smoke test failed: $url did not return 200. Check the Windows Event Log (IIS AspNetCore Module) and the pool identity."
}

Write-Host ''
Write-Host 'Deployment complete.' -ForegroundColor Green
Write-Host "  App      : http://localhost:$HttpPort/$ApplicationName/"
Write-Host "  Health   : $url"
Write-Host "  HTTPS    : https://localhost:$HttpsPort/$ApplicationName/ (self-signed certificate)"
Write-Host "  IIS logs : $LogDirectory"
