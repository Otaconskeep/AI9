# Registers the "MangaColorizerAI9" Scheduled Task so start_server.ps1 runs
# automatically at logon and the service survives reboots. Run this once,
# interactively, as the user who will be logged in when you want the
# server running (the GPU driver is WDDM, so this needs a real desktop
# session -- it is NOT set up as a headless SYSTEM service).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File register-task.ps1

$ErrorActionPreference = 'Stop'

$taskName = 'MangaColorizerAI9'
$repoRoot = Split-Path -Parent $PSScriptRoot   # .. from deploy/
$startScript = Join-Path $repoRoot 'deploy\start_server.ps1'
# If you cloned this guide separately from your actual deployment at
# C:\opt\manga-colorizer, point this at the real start_server.ps1 instead:
# $startScript = 'C:\opt\manga-colorizer\start_server.ps1'

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Task '$taskName' already exists, replacing it..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    # ExecutionTimeLimit MUST be zero (unlimited) -- Task Scheduler's default
    # 3-day limit will silently kill a long-running server otherwise.

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Manga-Colorizer GPU backend. Restarts automatically at logon and on crash.'

Write-Host "Registered. Starting it now..."
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 5
Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo | Format-List
