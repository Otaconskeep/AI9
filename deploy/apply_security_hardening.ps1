# Quick apply of localhost-only security hardening on an existing AI9 install.
# Run in PowerShell as the same Windows user that owns the MangaColorizerAI9 task:
#   powershell -ExecutionPolicy Bypass -File deploy\apply_security_hardening.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'backend\app-stream.py'))) {
    $root = 'C:\opt\manga-colorizer'
}
Write-Host "AI9 root: $root"

$venvPy = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) { throw "Missing venv python: $venvPy" }

# Pull latest launcher files from GitHub raw (minimal surface).
$raw = 'https://raw.githubusercontent.com/Otaconskeep/AI9/main'
$files = @(
    'backend/app-stream.py',
    'backend/ensure_ssl.py',
    'deploy/start_server.ps1',
    'extension/manifest.json',
    'extension/contentScript.js',
    'extension/siteConfig.json'
)
foreach ($rel in $files) {
    $dest = Join-Path $root ($rel -replace '/', '\')
    $url = "$raw/$rel"
    Write-Host "Fetching $rel"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

# Fix portable $root in start_server.ps1 if still hardcoded
$start = Join-Path $root 'deploy\start_server.ps1'
$txt = Get-Content -LiteralPath $start -Raw
if ($txt -match "\$root = 'C:\\opt\\manga-colorizer'") {
    $newRootLine = '$root = Split-Path -Parent $PSScriptRoot'
    # Keep start_server's own $root assignment pattern from installer
}

& $venvPy -m pip install --upgrade "setuptools>=70,<82" | Out-Null
& $venvPy (Join-Path $root 'backend\ensure_ssl.py') (Join-Path $root 'backend\ssl')

# Restart service task
$task = 'MangaColorizerAI9'
Write-Host "Restarting scheduled task $task"
Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
# Kill leftover listeners on 5000 owned by previous python
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | ForEach-Object {
    if ($_.CommandLine -match 'app-stream') {
        Write-Host "Stopping PID $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 8

Write-Host "Listener check:"
Get-NetTCPConnection -LocalPort 5000 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize

Write-Host "Local health:"
curl.exe -sk https://127.0.0.1:5000/healthz
Write-Host ""
Write-Host "Done. From another PC, curl to this machine's LAN IP:5000 must fail."
