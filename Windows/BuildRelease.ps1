param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$')]
    [string]$Version,
    [string]$MSBuildPath = 'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\arm64\MSBuild.exe',
    [string]$CertificateThumbprint,
    [string]$TimestampUrl
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'SendFileOverWiFi\SendFileOverWiFi.csproj'
$notes = Join-Path $PSScriptRoot 'RELEASE-NOTES.md'
$artifacts = Join-Path $PSScriptRoot (Join-Path 'artifacts' $Version)

if (-not (Test-Path $MSBuildPath)) { throw "MSBuild was not found: $MSBuildPath" }
if (-not (Test-Path $notes)) { throw "Release notes were not found: $notes" }

New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
foreach ($target in @(@{ Platform = 'x64'; Runtime = 'win-x64' }, @{ Platform = 'ARM64'; Runtime = 'win-arm64' })) {
    & $MSBuildPath $project /p:Configuration=Release /p:Platform=$($target.Platform) /p:RuntimeIdentifier=$($target.Runtime) /p:Version=$Version /m /nologo /v:minimal
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $($target.Runtime)" }

    $output = Join-Path $PSScriptRoot "SendFileOverWiFi\bin\$($target.Platform)\Release\net8.0-windows10.0.17763.0\$($target.Runtime)"
    if ($CertificateThumbprint) {
        & (Join-Path $PSScriptRoot 'SignRelease.ps1') -PublishDirectory $output -CertificateThumbprint $CertificateThumbprint -TimestampUrl $TimestampUrl
    }
    $staging = Join-Path $artifacts "SendFileOverWiFi-$Version-$($target.Runtime)"
    $archive = "$staging.zip"
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    if (Test-Path $archive) { Remove-Item -Force $archive }
    Copy-Item -Recurse -Force $output $staging
    Copy-Item $notes (Join-Path $staging 'RELEASE-NOTES.md')
    Compress-Archive -Path $staging -DestinationPath $archive -CompressionLevel Optimal
    Remove-Item -Recurse -Force $staging
    Write-Host "Created $archive"
}

$checksums = Join-Path $artifacts 'SHA256SUMS.txt'
Get-ChildItem $artifacts -Filter '*.zip' -File | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($_.Name)"
} | Set-Content -Path $checksums -Encoding ascii
Write-Host "Created $checksums"
