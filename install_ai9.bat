@echo off
REM ============================================================
REM  install_ai9.bat  /  public download name: AI9-Setup.bat
REM  Lone Downloads entry - fetches install_ai9.sh if needed,
REM  finds/installs Git Bash, then runs the real installer.
REM  Double-click this file. Do NOT type the filename in CMD.
REM ============================================================
setlocal EnableExtensions EnableDelayedExpansion
title AI9 Setup

REM --- encoding check: reject UTF-16 Save-As corruption; ASCII/UTF-8 OK ---
set "AI9_SETUP_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $p = $env:AI9_SETUP_SELF; if ([string]::IsNullOrWhiteSpace($p)) { Write-Host 'ERROR: installer path missing'; exit 2 }; if (-not (Test-Path -LiteralPath $p)) { Write-Host 'ERROR: installer file not found'; exit 2 }; $b = [IO.File]::ReadAllBytes($p); if ($b.Length -lt 8) { Write-Host 'ERROR: installer file empty'; exit 2 }; if ($b[0] -eq 255 -and $b[1] -eq 254) { Write-Host 'ERROR: UTF-16 encoding'; exit 3 }; if ($b[0] -eq 254 -and $b[1] -eq 255) { Write-Host 'ERROR: UTF-16 encoding'; exit 3 }; if ($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) { exit 0 }; if ($b[0] -eq 64) { exit 0 }; Write-Host 'ERROR: damaged encoding. Re-download from the Otaconskeep website.'; exit 4 }"
if errorlevel 1 goto ENC_FAIL
goto ENC_OK
:ENC_FAIL
echo.
echo ============================================================
echo                   AI9 SETUP STOPPED
echo ============================================================
echo.
echo  This installer file is damaged or was saved with the wrong encoding.
echo.
echo  What to do
echo  1. Delete this .bat file
echo  2. Open https://otaconskeep.com/ai9/#install
echo  3. Click Download AI9 Setup
echo  4. Double-click the new file from your Downloads folder
echo.
echo  Do NOT open raw.githubusercontent.com and use Save As.
echo  Do NOT type the filename into Command Prompt.
echo.
pause
exit /b 1
:ENC_OK

set "BRANCH=main"
set "RAW=https://raw.githubusercontent.com/Otaconskeep/AI9/%BRANCH%"
set "KEEP=%LOCALAPPDATA%\AI9"
set "INST=%KEEP%\installer"
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

echo.
echo ============================================================
echo                       AI9 SETUP
echo ============================================================
echo.
echo           MANGA COLORIZER // WINDOWS INSTALLER
echo                 Antonio G. Garcia // Otaconskeep
echo.
echo ============================================================
echo.
echo  Double-clicked correctly. Preparing files...
echo  Do not close this window.
echo.

REM Git checkout dev path: run the .sh beside this .bat when inside the repo.
set "WORK=%INST%"
if exist "%SCRIPT_DIR%\.git\HEAD" if exist "%SCRIPT_DIR%\install_ai9.sh" (
    set "WORK=%SCRIPT_DIR%"
    goto HAVE_SH
)

if not exist "%INST%" mkdir "%INST%" >nul 2>&1
set "WORK=%INST%"
echo  [1/3] Downloading install_ai9.sh ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $ErrorActionPreference='Stop'; $cb=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $url=('%RAW%/install_ai9.sh' + '?cb=' + $cb); $out=Join-Path $env:LOCALAPPDATA 'AI9\installer\install_ai9.sh'; New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null; Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ 'Cache-Control'='no-cache'; 'Pragma'='no-cache' }; if (-not (Test-Path -LiteralPath $out)) { exit 1 }; if ((Get-Item -LiteralPath $out).Length -lt 100) { exit 2 }; exit 0 }"
if errorlevel 1 (
    echo.
    echo  DOWNLOAD FAILED
    echo  Could not fetch install_ai9.sh from GitHub.
    echo  Check your internet connection, then double-click this file again.
    echo.
    pause
    exit /b 1
)
echo  [1/3] OK

REM Keep a local copy of this launcher next to the .sh for reruns
copy /Y "%~f0" "%INST%\install_ai9.bat" >nul 2>&1

:HAVE_SH
if not exist "%WORK%\install_ai9.sh" (
    echo  Missing install_ai9.sh in:
    echo    %WORK%
    pause
    exit /b 1
)

echo  [2/3] Locating Git Bash ...
set "BASH_EXE="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

REM Do NOT use bare "where bash" - that often hits the WSL stub, which AI9 refuses.
if not defined BASH_EXE (
    echo  Git Bash not found. Installing Git for Windows via winget...
    set "WINGET_EXE="
    where winget.exe >nul 2>nul && for /f "delims=" %%W in ('where winget.exe 2^>nul') do if not defined WINGET_EXE set "WINGET_EXE=%%W"
    REM WindowsApps App Execution Alias is often a 0-byte stub or directory.
    if defined WINGET_EXE (
        if exist "!WINGET_EXE!\*" set "WINGET_EXE="
    )
    if defined WINGET_EXE (
        for %%A in ("!WINGET_EXE!") do if %%~zA LSS 1024 set "WINGET_EXE="
    )
    if defined WINGET_EXE (
        "!WINGET_EXE!" --version >nul 2>nul
        if errorlevel 1 set "WINGET_EXE="
    )
    if not defined WINGET_EXE (
        echo.
        echo  winget is not available on this PC ^(or only a broken App Alias was found^).
        echo  Install Git for Windows from https://git-scm.com/download/win
        echo  then double-click this same Setup file again.
        echo  Or install "App Installer" from the Microsoft Store so winget works.
        echo.
        pause
        exit /b 1
    )
    "!WINGET_EXE!" install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
    if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
    if not defined BASH_EXE if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
)

if not defined BASH_EXE (
    echo.
    echo  Git was installed but Git Bash is not visible in this window yet.
    echo  Close this window, then double-click the same Setup file again.
    echo.
    pause
    exit /b 1
)
echo  [2/3] OK  %BASH_EXE%

echo  [3/3] Launching AI9 installer...
echo.
"%BASH_EXE%" -lc "cd \"$(cygpath -u '%WORK%')\" && ./install_ai9.sh"
set "RC=!ERRORLEVEL!"

echo.
echo ============================================================
if "!RC!"=="0" (
    echo  AI9 setup finished.
) else (
    echo  AI9 setup stopped with exit code !RC!.
    echo  Read the messages above. Fix the issue, then double-click
    echo  this same Setup file again - it resumes safely.
)
echo ============================================================
echo.
pause
exit /b !RC!
