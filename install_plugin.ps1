# =============================================================================
#  TokeerDRM - one-click plugin installer
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

# Inspect Millennium's actual state. "Installed" (a few files present) is NOT
# the same as "set up" - the plugin tab only appears when the injection loader
# (user32.dll proxy), the embedded Python runtime, AND the core dir all exist.
function Get-MillenniumState($s) {
    $loader = Test-Path (Join-Path $s 'user32.dll')
    $python = [bool](Get-ChildItem -Path $s -Filter 'python3*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)
    $coreExt = Test-Path (Join-Path $s 'ext')
    $coreMil = Test-Path (Join-Path $s 'millennium')
    [pscustomobject]@{
        Loader = $loader
        Python = $python
        Core   = ($coreExt -or $coreMil)
        Setup  = ($loader -and $python -and ($coreExt -or $coreMil))
    }
}

# --- 2. Millennium -----------------------------------------------------------
Step 'Checking Millennium...'
$mil = Get-MillenniumState $steam
if ($mil.Setup) {
    Good 'Millennium is installed and set up.'
} else {
    if ($mil.Loader -or $mil.Python -or $mil.Core) {
        Warn 'Millennium looks only PARTIALLY installed (a previous setup never finished).'
        Warn ("   loader={0}  python={1}  core={2}  -> re-running the installer to complete it." -f $mil.Loader, $mil.Python, $mil.Core)
    } else {
        Warn 'Millennium not found - downloading the latest installer...'
    }
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/SteamClientHomebrew/Installer/releases/latest' -Headers $UA
        $asset = $rel.assets | Where-Object { $_.name -match '(?i)windows.*\.exe$' } | Select-Object -First 1
        if (-not $asset) { Die 'Could not find the Millennium Windows installer.' }
        $mexe = Join-Path $env:TEMP 'MillenniumInstaller.exe'
        Invoke-WebRequest $asset.browser_download_url -OutFile $mexe -Headers $UA
        Good 'Launching the Millennium installer - click Install and let it FINISH, then come back here.'
        Start-Process -FilePath $mexe -Wait
    } catch { Die "Millennium install failed: $($_.Exception.Message)" }

    # HARD re-check: never continue on a half-installed Millennium - the plugin
    # tab will silently never appear if loader/python/core aren't all present.
    $mil = Get-MillenniumState $steam
    if (-not $mil.Setup) {
        Die ("Millennium still isn't fully set up after the installer " +
             "(loader=$($mil.Loader) python=$($mil.Python) core=$($mil.Core)). " +
             "Re-run the Millennium installer, make sure it finishes without errors, then run this again.")
    }
    Good 'Millennium installed and set up.'
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

# Extract to a temp dir first - some release zips wrap everything in a top-level
# folder (TokeerDRM/ or a versioned dir). Locate the folder that actually holds
# plugin.json and copy from there, so files land FLAT in $dest where Millennium
# looks for them (otherwise the plugin is nested one level too deep -> no tab).
$tmpx = Join-Path $env:TEMP ('TokeerDRM-x-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpx | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpx)
$srcRoot = $tmpx
$pj = Get-ChildItem -Path $tmpx -Recurse -Filter 'plugin.json' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pj) { $srcRoot = $pj.Directory.FullName }
Get-ChildItem -LiteralPath $srcRoot -Force | Copy-Item -Destination $dest -Recurse -Force
Remove-Item $tmpx -Recurse -Force -ErrorAction SilentlyContinue
Good "Plugin installed to $dest"

# HARD check: the folder must actually contain the files Millennium needs - the
# manifest, the lua backend, and the compiled frontend (the frontend is what
# renders the Properties tab). If any is missing, the tab will never show.
$need = [ordered]@{
    'plugin.json'                = (Join-Path $dest 'plugin.json')
    'backend\main.lua'           = (Join-Path $dest 'backend\main.lua')
    '.millennium\Dist\index.js'  = (Join-Path $dest '.millennium\Dist\index.js')
}
$missing = @()
foreach ($k in $need.Keys) { if (-not (Test-Path $need[$k])) { $missing += $k } }
if ($missing.Count) {
    Die ("Plugin files are incomplete - missing: " + ($missing -join ', ') +
         ". The release zip looks broken; re-run after the next release or report this.")
}
try { $pjName = (Get-Content (Join-Path $dest 'plugin.json') -Raw | ConvertFrom-Json).name } catch { $pjName = $null }
if ($pjName -ne 'TokeerDRM') { Warn "plugin.json name is '$pjName' (expected 'TokeerDRM')." }
Good 'Plugin files verified.'

# --- 4. Enable the plugin (plugins.enabledPlugins += "TokeerDRM") ------------
Step 'Enabling the plugin...'

# Millennium's JSON parser dislikes a UTF-8 BOM (PS 5.1 Set-Content adds one),
# which can blank the whole config and silently disable every plugin. Write raw.
function Write-JsonNoBom($path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function Enable-InConfig($cfg) {
    try {
        $j = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $j.plugins) { $j | Add-Member -NotePropertyName plugins -NotePropertyValue ([pscustomobject]@{}) -Force }
        $list = @(); if ($j.plugins.enabledPlugins) { $list = @($j.plugins.enabledPlugins) }
        if ($list -notcontains 'TokeerDRM') { $list += 'TokeerDRM' }
        $j.plugins | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue $list -Force
        Write-JsonNoBom $cfg $j
        # read it back and confirm it actually persisted
        $chk = Get-Content $cfg -Raw | ConvertFrom-Json
        return (@($chk.plugins.enabledPlugins) -contains 'TokeerDRM')
    } catch { return $false }
}

$cfgs = New-Object System.Collections.Generic.List[string]
foreach ($c in @("$steam\ext\data\settings.json", "$steam\millennium\settings.json", "$env:APPDATA\millennium\settings.json")) { $cfgs.Add($c) }
foreach ($root in @("$steam\ext", "$steam\millennium", "$env:APPDATA\millennium")) {
    if (Test-Path $root) {
        Get-ChildItem -Path $root -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try { if ((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'enabledPlugins') { $cfgs.Add($_.FullName) } } catch {}
        }
    }
}

$enabled = $false
foreach ($cfg in ($cfgs | Select-Object -Unique)) {
    if (-not (Test-Path $cfg)) { continue }
    if (Enable-InConfig $cfg) { Good "Enabled + verified in $cfg"; $enabled = $true }
}

# Fresh installs may not have a settings.json yet - create the canonical one so
# the plugin is already enabled the first time Millennium loads.
if (-not $enabled) {
    $canon = if (Test-Path "$steam\ext") { "$steam\ext\data\settings.json" }
             elseif (Test-Path "$steam\millennium") { "$steam\millennium\settings.json" }
             else { "$env:APPDATA\millennium\settings.json" }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $canon) | Out-Null
        if (-not (Test-Path $canon)) { Write-JsonNoBom $canon ([pscustomobject]@{ plugins = [pscustomobject]@{ enabledPlugins = @() } }) }
        if (Enable-InConfig $canon) { Good "Created config + enabled in $canon"; $enabled = $true }
    } catch {}
}

if (-not $enabled) { Warn "Couldn't auto-enable. After Steam opens: Steam menu > Millennium > Plugins > turn ON 'TokeerDRM'." }

# --- 5. Final verification (before restart) ----------------------------------
Step 'Verifying installation...'
$mil2 = Get-MillenniumState $steam
$okCore    = $mil2.Setup
$okFiles   = (Test-Path (Join-Path $dest 'plugin.json')) -and `
             (Test-Path (Join-Path $dest 'backend\main.lua')) -and `
             (Test-Path (Join-Path $dest '.millennium\Dist\index.js'))
$okEnabled = $enabled
if ($okCore)    { Good 'Millennium core set up (loader + python + core)' } else { Warn 'Millennium core NOT fully set up' }
if ($okFiles)   { Good 'Plugin files present (manifest + backend + frontend)' } else { Warn 'Plugin files incomplete' }
if ($okEnabled) { Good 'Plugin enabled + verified in settings' } else { Warn 'Plugin not confirmed enabled' }

# --- 6. Restart Steam --------------------------------------------------------
Step 'Restarting Steam...'
Start-Process (Join-Path $steam 'steam.exe')
Start-Sleep 5

if ($okCore -and $okFiles -and $okEnabled) {
    Write-Host "`n=== Done! Everything checks out. ===" -ForegroundColor Green
    Write-Host "1. In Steam, right-click ANY game -> Properties." -ForegroundColor Cyan
    Write-Host "2. The LAST tab is 'TokeerDRM'. Paste your code there and click Apply." -ForegroundColor Cyan
    Write-Host "3. Launch the game from Steam within ~30 minutes." -ForegroundColor Cyan
} else {
    Write-Host "`n=== Setup finished with WARNINGS - the tab may not appear yet. ===" -ForegroundColor Yellow
    if (-not $okCore)    { Write-Host " - Millennium isn't fully set up. Re-run the Millennium installer and let it finish, then re-run this script." -ForegroundColor Yellow }
    if (-not $okFiles)   { Write-Host " - Plugin files are incomplete. Re-run this script; if it persists the release zip is bad." -ForegroundColor Yellow }
    if (-not $okEnabled) { Write-Host " - Couldn't confirm the plugin is enabled. After Steam opens: Steam menu > Millennium > Plugins > turn ON 'TokeerDRM', then restart Steam." -ForegroundColor Yellow }
}
Read-Host "`nPress Enter to close"
