#Requires -Version 5.1
# TokeerDRM - in-place plugin updater. Downloads the latest release zip from GitHub,
# closes Steam (so Millennium releases the plugin files), extracts the new build over
# the existing plugin folder, and restarts Steam so Millennium reloads it. Launched by
# the plugin's "Update now" button - no browser, no manual download.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$UA = @{ "User-Agent" = "TokeerDRM" }
$Host.UI.RawUI.WindowTitle = "TokeerDRM - plugin update"

# Log + keep the window open on failure so an error never "just flashes and closes".
$LogPath = Join-Path $env:TEMP "tokeerdrm_plugin_update.log"
try { Start-Transcript -Path $LogPath -Force | Out-Null } catch {}
trap {
    Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Full log: $LogPath" -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host "`nUpdate failed - press Enter to close"
    exit 1
}

function Get-SteamPath {
    foreach ($r in @(
        @{P="HKCU:\Software\Valve\Steam";K="SteamPath"},
        @{P="HKLM:\SOFTWARE\WOW6432Node\Valve\Steam";K="InstallPath"},
        @{P="HKLM:\SOFTWARE\Valve\Steam";K="InstallPath"})) {
        $v = (Get-ItemProperty $r.P -Name $r.K -ErrorAction SilentlyContinue).$($r.K)
        if ($v -and (Test-Path (Join-Path ($v -replace '/','\') "steam.exe"))) { return ($v -replace '/','\') }
    }
    throw "Steam not found"
}

Write-Host "`n=== TokeerDRM: updating the plugin ===`n" -ForegroundColor Cyan
$steam = Get-SteamPath

# Existing plugin folder - Millennium has used both layouts across versions.
$dest = @("$steam\plugins\TokeerDRM", "$steam\millennium\plugins\TokeerDRM") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dest) { throw "TokeerDRM plugin folder not found" }
Write-Host "[+] Plugin: $dest" -ForegroundColor Green

# 1. latest release zip
Write-Host "[*] Finding latest release..."
$rel = Invoke-RestMethod "https://api.github.com/repos/Tesla697/TokeerDRM/releases/latest" -Headers $UA
$asset = $rel.assets | Where-Object { $_.name -match "(?i)\.zip$" } | Select-Object -First 1
if (-not $asset) { throw "No plugin zip on the latest release" }
$zip = Join-Path $env:TEMP "TokeerDRM-plugin-update.zip"
Write-Host "[*] Downloading $($asset.name)..."
Invoke-WebRequest $asset.browser_download_url -OutFile $zip -Headers $UA

# 2. close Steam so Millennium releases the plugin's files
Write-Host "[*] Closing Steam..."
& (Join-Path $steam "steam.exe") -shutdown 2>$null
for ($i=0; $i -lt 30; $i++) { Start-Sleep 1; if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { break } }
Start-Sleep 2

# 3. extract the new build over the existing plugin folder (server.txt ships in the
#    zip, so the correct one is restored too)
Write-Host "[*] Installing update..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$tmp = Join-Path $env:TEMP ("tdrm_upd_" + [guid]::NewGuid().ToString("N"))
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
Copy-Item (Join-Path $tmp '*') $dest -Recurse -Force
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zip -Force -ErrorAction SilentlyContinue

# 4. restart Steam -> Millennium reloads the plugin
Write-Host "[*] Restarting Steam..."
Start-Process (Join-Path $steam "steam.exe")
Write-Host "`n[OK] Plugin updated to $($rel.tag_name). Open any game's Properties > TokeerDRM.`n" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Start-Sleep 3
