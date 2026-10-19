[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory = $true)]
    [string]$CertificateThumbprint,
    [string]$MSBuildPath = 'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\arm64\MSBuild.exe',
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $IsccPath) {
    $IsccPath = @(
        'C:\Program Files (x86)\Inno Setup 7\ISCC.exe',
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    throw 'Inno Setup Compiler (ISCC.exe) was not found. Install Inno Setup 7 before building the installer.'
}

& (Join-Path $root 'BuildRelease.ps1') -Version $Version -MSBuildPath $MSBuildPath -CertificateThumbprint $CertificateThumbprint

$script = Join-Path $root 'Installer\SendFileOverWiFi.iss'
$signCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$q$root\SignRelease.ps1`$q -FilePath `$f -CertificateThumbprint $CertificateThumbprint"
& $IsccPath "/ssendfile=$signCommand" "/DAppVersion=$Version" "/DCertificateThumbprint=$CertificateThumbprint" $script
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }

$artifacts = Join-Path $root "artifacts\$Version"
$installer = Join-Path $artifacts "SendFileOverWiFi-Setup-$Version.exe"

$checksums = Join-Path $artifacts 'SHA256SUMS.txt'
Get-ChildItem $artifacts -File | Where-Object { $_.Extension -in '.zip', '.exe' } | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($_.Name)"
} | Set-Content -Path $checksums -Encoding ascii

Write-Host "Created signed universal installer: $installer"
