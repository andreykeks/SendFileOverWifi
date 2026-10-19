[CmdletBinding()]
param(
    [string]$Subject = 'CN=SendFile over WiFi Development',
    [string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Documents\SendFileOverWiFi Signing'),
    [SecureString]$PfxPassword
)

$ErrorActionPreference = 'Stop'

if ($null -eq $PfxPassword) {
    $PfxPassword = Read-Host 'Enter a new password for the PFX backup' -AsSecureString
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$pfxPath = Join-Path $OutputDirectory 'SendFileOverWiFi-development.pfx'
$cerPath = Join-Path $OutputDirectory 'SendFileOverWiFi-development.cer'
if ((Test-Path $pfxPath) -or (Test-Path $cerPath)) {
    throw "A signing backup already exists in $OutputDirectory. Keep that certificate to preserve the signing identity."
}

$certificate = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears(5)

Export-PfxCertificate -Cert $certificate -FilePath $pfxPath -Password $PfxPassword | Out-Null
Export-Certificate -Cert $certificate -FilePath $cerPath | Out-Null

Write-Host "Created certificate: $($certificate.Thumbprint)"
Write-Host "Encrypted PFX backup: $pfxPath"
Write-Host "Public certificate: $cerPath"
Write-Host 'Copy the PFX to a second protected local location outside this VM. Never commit or upload its password.'
Write-Host "To restore on another Windows machine: Import-PfxCertificate -FilePath '$pfxPath' -CertStoreLocation 'Cert:\CurrentUser\My' -Password (Read-Host -AsSecureString)"
