param(
    [Parameter(Mandatory = $true)]
    [string]$TargetExe
)

$resolvedTarget = (Resolve-Path -LiteralPath $TargetExe -ErrorAction Stop).Path
$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
$shortcutPath = Join-Path $desktop 'SendFile over WiFi.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $resolvedTarget
$shortcut.WorkingDirectory = Split-Path -Parent $resolvedTarget
$shortcut.Description = 'SendFile over WiFi'
$shortcut.IconLocation = "$resolvedTarget,0"
$shortcut.Save()

Write-Output $shortcutPath
