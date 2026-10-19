[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'PublishDirectory')]
    [string]$PublishDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'SingleFile')]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string]$CertificateThumbprint,
    [string]$TimestampUrl
)

$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'PublishDirectory' -and -not (Test-Path $PublishDirectory)) {
    throw "Publish directory was not found: $PublishDirectory"
}
if ($PSCmdlet.ParameterSetName -eq 'SingleFile' -and -not (Test-Path $FilePath -PathType Leaf)) {
    throw "File to sign was not found: $FilePath"
}

$signToolRoots = @(
    'C:\Program Files (x86)\Windows Kits\10\bin',
    'C:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages\microsoft.windows.sdk.buildtools'
) | Where-Object { Test-Path $_ }
$signToolCandidates = foreach ($root in $signToolRoots) {
    Get-ChildItem $root -Filter signtool.exe -Recurse |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' }
}
$signTool = $signToolCandidates | Sort-Object FullName -Descending | Select-Object -First 1
if ($null -eq $signTool) { throw 'Windows SDK SignTool was not found.' }

$normalizedThumbprint = $CertificateThumbprint -replace '\s', ''
$certificate = Get-ChildItem "Cert:\CurrentUser\My\$normalizedThumbprint" -ErrorAction SilentlyContinue
if ($null -eq $certificate) {
    throw "Signing certificate $CertificateThumbprint was not found in Cert:\CurrentUser\My. Restore its PFX backup first."
}

if ($PSCmdlet.ParameterSetName -eq 'PublishDirectory') {
    $files = @(
        Get-Item (Join-Path $PublishDirectory 'SendFileOverWiFi.exe') -ErrorAction SilentlyContinue
        Get-Item (Join-Path $PublishDirectory 'SendFileOverWiFi.dll') -ErrorAction SilentlyContinue
    ) | Where-Object { $null -ne $_ }
    if ($files.Count -ne 2) { throw "Expected SendFileOverWiFi.exe and SendFileOverWiFi.dll in $PublishDirectory." }
} else {
    $files = @(Get-Item $FilePath)
}

foreach ($file in $files) {
    $arguments = @('sign', '/fd', 'SHA256', '/sha1', $normalizedThumbprint, '/s', 'My', '/d', 'SendFile over WiFi')
    if ($TimestampUrl) { $arguments += @('/tr', $TimestampUrl, '/td', 'SHA256') }
    $arguments += $file.FullName
    & $signTool.FullName @arguments
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $($file.FullName)" }

    # Inno Setup keeps its temporary uninstaller open while its SignTool runs.
    # SignTool's zero exit code is authoritative there; reopening the file for
    # PowerShell inspection would fail despite a successful signature.
    if ($PSCmdlet.ParameterSetName -eq 'PublishDirectory') {
        $signature = Get-AuthenticodeSignature -FilePath $file.FullName
        if ($signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
            throw "Unexpected signer after signing: $($file.FullName)"
        }
    }
}

Write-Host "Signed $($files.Count) files using certificate $($certificate.Thumbprint)."
Write-Host 'A self-signed certificate remains untrusted on other PCs until its public certificate is explicitly trusted there.'
