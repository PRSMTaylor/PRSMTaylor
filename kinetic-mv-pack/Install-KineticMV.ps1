[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Uninstall,
    [switch]$AllUsers,
    [string]$Destination,
    [string]$ScriptsDestination
)
# Installs (or removes) the KMV effects pack for DaVinci Resolve on Windows.
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'Effects'

if (-not $Destination) {
    $rel = 'Blackmagic Design\DaVinci Resolve\Support\Fusion\Templates\Edit\Effects'
    $base = if ($AllUsers) { $env:ProgramData } else { $env:APPDATA }
    $Destination = Join-Path $base $rel
}

if (-not $ScriptsDestination) {
    $sbase = if ($AllUsers) { $env:ProgramData } else { $env:APPDATA }
    $ScriptsDestination = Join-Path $sbase 'Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Edit'
}

$files = Get-ChildItem -Path $src -Filter 'KMV *.setting' -ErrorAction SilentlyContinue
if (-not $files -and -not $Uninstall) { throw "No presets found in $src" }

if ($Uninstall) {
    Get-ChildItem -Path $Destination -Filter 'KMV *.setting' -ErrorAction SilentlyContinue |
        ForEach-Object { if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove')) { Remove-Item $_.FullName } }
    Get-ChildItem -Path $ScriptsDestination -Filter 'KMV *.lua' -ErrorAction SilentlyContinue |
        ForEach-Object { if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove')) { Remove-Item $_.FullName } }
    Write-Host "Removed KMV presets from $Destination and scripts from $ScriptsDestination"
    return
}

if (-not (Test-Path $Destination)) {
    if ($PSCmdlet.ShouldProcess($Destination, 'Create folder')) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
}
foreach ($f in $files) {
    if ($PSCmdlet.ShouldProcess($f.Name, "Copy to $Destination")) {
        Copy-Item -LiteralPath $f.FullName -Destination $Destination -Force
    }
}
if (-not (Test-Path $ScriptsDestination) -and $PSCmdlet.ShouldProcess($ScriptsDestination, 'Create folder')) {
    New-Item -ItemType Directory -Path $ScriptsDestination -Force | Out-Null
}
if ($PSCmdlet.ShouldProcess('KMV Effects Launcher.lua', "Copy to $ScriptsDestination")) {
    Copy-Item -Path (Join-Path $PSScriptRoot 'Scripts\KMV *.lua') -Destination $ScriptsDestination -Force
}
Write-Host "Installed $($files.Count) presets to $Destination"
Write-Host "Installed launcher script to $ScriptsDestination (Workspace > Scripts > Edit)"
Write-Host 'Restart DaVinci Resolve, then search "KMV" in Effects > Edit Effects.'
