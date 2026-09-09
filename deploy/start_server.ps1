# Manga Colorizer supervisor loop.
# Restarts app-stream.py automatically if it exits/crashes for any reason
# (CUDA fault, unhandled exception, etc). Intended to be launched by the
# "MangaColorizerAI9" Scheduled Task at user logon, so the service survives
# reboots without any manual step.

$ErrorActionPreference = 'Continue'
$root = 'C:\opt\manga-colorizer'
$venvPython = Join-Path $root 'venv\Scripts\python.exe'
$backendDir = Join-Path $root 'backend'
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }

Set-Location $backendDir

while ($true) {
    $stamp = Get-Date -Format 'yyyyMMdd'
    $logFile = Join-Path $logDir "server-$stamp.log"
    "[$(Get-Date -Format o)] Starting app-stream.py" | Out-File -Append -Encoding utf8 $logFile

    & $venvPython -u app-stream.py --idle_unload_seconds 900 *>> $logFile

    $exitCode = $LASTEXITCODE
    "[$(Get-Date -Format o)] app-stream.py exited with code $exitCode, restarting in 5s" | Out-File -Append -Encoding utf8 $logFile
    Start-Sleep -Seconds 5
}
