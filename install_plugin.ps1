# =============================================================================
#  TokeerDRM — one-click plugin installer
#  Installs Millennium (if missing), drops in the TokeerDRM plugin, enables it,
#  and restarts Steam. Run:  irm https://raw.githubusercontent.com/Tesla697/TokeerDRM/main/install_plugin.ps1 | iex
# =============================================================================

# --- self-elevate (we write into the Steam folder + install Millennium) ------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-Command",
        "irm https://raw.githubusercontent.com/Tesla697/TokeerDRM/main/install_plugin.ps1 | iex"
    return
}

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'TokeerDRM Setup'
$UA = @{ 'User-Agent' = 'TokeerDRM' }

function Step($m) { Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "    [+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "`n[-] $m" -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }

Write-Host "`n=== TokeerDRM Plugin Setup ===`n" -ForegroundColor Magenta

# --- 1. Steam ----------------------------------------------------------------
Step 'Finding Steam...'
$steam = $null
foreach ($r in @(
    @{P='HKCU:\Software\Valve\Steam';K='SteamPath'},
    @{P='HKLM:\SOFTWARE\WOW6432Node\Valve\Steam';K='InstallPath'},
    @{P='HKLM:\SOFTWARE\Valve\Steam';K='InstallPath'})) {
    try {
        $v = (Get-ItemProperty $r.P -Name $r.K -ErrorAction SilentlyContinue).$($r.K)
        if ($v) { $v = ($v -replace '/','\'); if (Test-Path (Join-Path $v 'steam.exe')) { $steam = $v; break } }
    } catch {}
}
if (-not $steam) { Die 'Steam not found. Install and run Steam once, then re-run this.' }
Good "Steam: $steam"

function Test-Millennium($s) {
    (Test-Path (Join-Path $s 'user32.dll')) -or (Test-Path (Join-Path $s 'millennium')) -or `
    (Test-Path (Join-Path $s 'ext\data')) -or (Test-Path (Join-Path $s 'python311.dll'))
}

# --- 2. Millennium -----------------------------------------------------------
Step 'Checking Millennium...'
if (Test-Millennium $steam) {
    Good 'Millennium already installed.'
} else {
    Warn 'Millennium not found — downloading the latest installer...'
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/SteamClientHomebrew/Installer/releases/latest' -Headers $UA
        $asset = $rel.assets | Where-Object { $_.name -match '(?i)windows.*\.exe$' } | Select-Object -First 1
        if (-not $asset) { Die 'Could not find the Millennium Windows installer.' }
        $mexe = Join-Path $env:TEMP 'MillenniumInstaller.exe'
        Invoke-WebRequest $asset.browser_download_url -OutFile $mexe -Headers $UA
        Good 'Launching the Millennium installer — click through it (Install), then it returns here.'
        Start-Process -FilePath $mexe -Wait
    } catch { Die "Millennium install failed: $($_.Exception.Message)" }
    if (Test-Millennium $steam) { Good 'Millennium installed.' } else { Warn 'Could not confirm Millennium — continuing anyway.' }
}

# --- 3. Download + place the plugin ------------------------------------------
Step 'Downloading the TokeerDRM plugin...'
$prel = Invoke-RestMethod 'https://api.github.com/repos/Tesla697/TokeerDRM/releases/latest' -Headers $UA
$zipAsset = $prel.assets | Where-Object { $_.name -match '(?i)\.zip$' } | Select-Object -First 1
if (-not $zipAsset) { Die 'Plugin zip not found on the latest release.' }
$zip = Join-Path $env:TEMP 'TokeerDRM-plugin.zip'
Invoke-WebRequest $zipAsset.browser_download_url -OutFile $zip -Headers $UA
Good "Got $($zipAsset.name)"

# plugins folder: use whichever Millennium already created, else the standard one
$pluginsDir = @("$steam\plugins", "$steam\millennium\plugins") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pluginsDir) { $pluginsDir = "$steam\plugins"; New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null }
$dest = Join-Path $pluginsDir 'TokeerDRM'

Step "Closing Steam to install the plugin..."
& (Join-Path $steam 'steam.exe') -shutdown 2>$null
for ($i=0; $i -lt 20; $i++) { Start-Sleep 1; if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { break } }
Get-Process steam,steamwebhelper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
Good "Plugin installed to $dest"

# --- 4. Enable the plugin (plugins.enabledPlugins += "TokeerDRM") ------------
Step 'Enabling the plugin...'
$enabled = $false
$cfgs = New-Object System.Collections.Generic.List[string]
foreach ($c in @("$steam\ext\data\settings.json", "$steam\millennium\settings.json", "$env:APPDATA\millennium\settings.json")) { $cfgs.Add($c) }
foreach ($root in @("$steam\ext", "$steam\millennium", "$env:APPDATA\millennium")) {
    if (Test-Path $root) {
        Get-ChildItem -Path $root -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try { if ((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'enabledPlugins') { $cfgs.Add($_.FullName) } } catch {}
        }
    }
}
foreach ($cfg in ($cfgs | Select-Object -Unique)) {
    if (-not (Test-Path $cfg)) { continue }
    try {
        $j = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $j.plugins) { $j | Add-Member -NotePropertyName plugins -NotePropertyValue ([pscustomobject]@{}) -Force }
        $list = @(); if ($j.plugins.enabledPlugins) { $list = @($j.plugins.enabledPlugins) }
        if ($list -notcontains 'TokeerDRM') { $list += 'TokeerDRM' }
        $j.plugins | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue $list -Force
        $j | ConvertTo-Json -Depth 30 | Set-Content $cfg -Encoding UTF8
        Good "Enabled in $cfg"
        $enabled = $true
    } catch {}
}
if (-not $enabled) { Warn "Couldn't auto-enable. After Steam opens: Steam menu > Millennium > Plugins > turn ON 'TokeerDRM'." }

# --- 5. Restart Steam --------------------------------------------------------
Step 'Restarting Steam...'
Start-Process (Join-Path $steam 'steam.exe')
Start-Sleep 5

Write-Host "`n=== Done! ===" -ForegroundColor Green
Write-Host "1. In Steam, right-click ANY game -> Properties." -ForegroundColor Cyan
Write-Host "2. The LAST tab is 'TokeerDRM'. Paste your code there and click Apply." -ForegroundColor Cyan
Write-Host "3. Launch the game from Steam within ~30 minutes." -ForegroundColor Cyan
if (-not $enabled) { Write-Host "`n(If you don't see the tab, enable 'TokeerDRM' under Steam > Millennium > Plugins, then restart Steam.)" -ForegroundColor Yellow }
Read-Host "`nPress Enter to close"
